import { randomUUID } from "node:crypto";
import { FieldPath, Timestamp } from "firebase-admin/firestore";
import { HttpsError, onCall } from "firebase-functions/v2/https";
import { onSchedule } from "firebase-functions/v2/scheduler";
import * as logger from "firebase-functions/logger";
import { db } from "./admin";
import { enforceCallableAppCheck } from "./callable_options";
import {
  deleteStoredObject,
  objectLedgerRef,
  quotaRef,
  quotaUsageState,
  R2_STORAGE_LIMIT_BYTES,
} from "./media_quota";
import { r2ListPage } from "./r2_gateway";
import { expireReservation } from "./media_uploads";
import { R2_GATEWAY_PRIVATE_JWK } from "./r2_gateway";

const FUNCTION_REGION = "asia-southeast1";
const PAGE_SIZE = 400;
const RECONCILIATION_LEASE_MS = 10 * 60 * 1000;

interface InventoryObject {
  key: string;
  size: number;
  etag: string;
  uploadedAt: string;
  customMetadata: Record<string, string>;
}

interface ReconciliationResult {
  reconciliationId: string;
  status: "completed" | "waiting" | "busy" | "attention";
  objectCount?: number;
  actualBytes?: number;
  missingObjectCount?: number;
  orphanedObjectCount?: number;
  sizeMismatchCount?: number;
  pendingReservationCount?: number;
}

function isTimestamp(value: unknown): value is Timestamp {
  return value instanceof Timestamp;
}

async function pages<T>(collection: string, visit: (docs: FirebaseFirestore.QueryDocumentSnapshot[]) => Promise<void>): Promise<void> {
  let cursor: FirebaseFirestore.QueryDocumentSnapshot | undefined;
  while (true) {
    let query = db.collection(collection).orderBy(FieldPath.documentId()).limit(PAGE_SIZE);
    if (cursor) query = query.startAfter(cursor);
    const page = await query.get();
    if (page.empty) return;
    await visit(page.docs);
    cursor = page.docs[page.docs.length - 1];
    if (page.size < PAGE_SIZE) return;
  }
}

async function acquireLock(reconciliationId: string): Promise<boolean> {
  return db.runTransaction(async (transaction) => {
    const current = await transaction.get(quotaRef);
    const data = current.data();
    const now = Timestamp.now();
    if (data?.maintenanceLock === true && isTimestamp(data.reconciliationLeaseUntil) &&
        data.reconciliationLeaseUntil.toMillis() > now.toMillis()) return false;
    const usedBytes = Number.isSafeInteger(data?.usedBytes) && Number(data?.usedBytes) >= 0 ? Number(data?.usedBytes) : 0;
    const reservedBytes = Number.isSafeInteger(data?.reservedBytes) && Number(data?.reservedBytes) >= 0 ? Number(data?.reservedBytes) : 0;
    transaction.set(quotaRef, {
      storageProvider: "cloudflare_r2",
      limitBytes: R2_STORAGE_LIMIT_BYTES,
      usedBytes,
      reservedBytes,
      remainingBytes: Math.max(0, R2_STORAGE_LIMIT_BYTES - usedBytes - reservedBytes),
      usagePercent: ((usedBytes + reservedBytes) / R2_STORAGE_LIMIT_BYTES) * 100,
      uploadEnabled: false,
      maintenanceLock: true,
      reconciliationId,
      reconciliationStartedAt: data?.reconciliationStartedAt ?? now,
      reconciliationLeaseUntil: Timestamp.fromMillis(now.toMillis() + RECONCILIATION_LEASE_MS),
      reconciliationState: "running",
      updatedAt: now,
    }, { merge: true });
    return true;
  });
}

async function setWaiting(reconciliationId: string, expiresAt?: Timestamp): Promise<void> {
  await db.runTransaction(async (transaction) => {
    const snapshot = await transaction.get(quotaRef);
    if (snapshot.data()?.reconciliationId !== reconciliationId) return;
    const now = Timestamp.now();
    transaction.update(quotaRef, {
      uploadEnabled: false,
      maintenanceLock: true,
      reconciliationState: "waiting-for-active-operations",
      reconciliationLeaseUntil: expiresAt && expiresAt.toMillis() > now.toMillis()
        ? expiresAt
        : Timestamp.fromMillis(now.toMillis() + RECONCILIATION_LEASE_MS),
      updatedAt: now,
    });
  });
}

async function refreshLease(reconciliationId: string): Promise<void> {
  const snapshot = await quotaRef.get();
  if (snapshot.data()?.reconciliationId !== reconciliationId || snapshot.data()?.maintenanceLock !== true) {
    throw new HttpsError("aborted", "The R2 reconciliation lock was lost.");
  }
  await quotaRef.update({
    reconciliationLeaseUntil: Timestamp.fromMillis(Date.now() + RECONCILIATION_LEASE_MS),
    updatedAt: Timestamp.now(),
  });
}

async function cleanupExpiredReservations(): Promise<{ pending: number; nextExpiry?: Timestamp }> {
  const now = Timestamp.now();
  let pending = 0;
  let nextExpiry: Timestamp | undefined;
  const expired: FirebaseFirestore.QueryDocumentSnapshot[] = [];
  await pages("uploadReservations", async (docs) => {
    for (const doc of docs) {
      const data = doc.data();
      if (data.status !== "reserved") continue;
      if (isTimestamp(data.expiresAt) && data.expiresAt.toMillis() <= now.toMillis()) expired.push(doc);
      else {
        pending++;
        if (isTimestamp(data.expiresAt) && (!nextExpiry || data.expiresAt.toMillis() < nextExpiry.toMillis())) nextExpiry = data.expiresAt;
      }
    }
  });
  for (const reservation of expired) await expireReservation(reservation.id);
  return { pending, nextExpiry };
}

async function retryIncompleteDeletions(): Promise<number> {
  const deleting: FirebaseFirestore.QueryDocumentSnapshot[] = [];
  await pages("storageObjects", async (docs) => {
    for (const doc of docs) if (doc.data().accountingState === "deleting") deleting.push(doc);
  });
  for (const ledger of deleting) {
    const data = ledger.data();
    if (typeof data.objectKey === "string") {
      await deleteStoredObject(data.objectKey, "system:reconciliation", "incomplete-deletion-retry");
    }
  }
  return deleting.length;
}

async function getR2Inventory(reconciliationId: string): Promise<{ objects: InventoryObject[]; totalBytes: number }> {
  const objects: InventoryObject[] = [];
  let cursor: string | undefined;
  let totalBytes = 0;
  do {
    const page = await r2ListPage(cursor, 1000);
    for (const object of page.objects) {
      if (typeof object.key !== "string" || !Number.isSafeInteger(object.size) || object.size < 0) {
        throw new HttpsError("data-loss", "R2 returned an object with invalid size metadata.");
      }
      objects.push(object);
      totalBytes += object.size;
      if (!Number.isSafeInteger(totalBytes)) throw new HttpsError("data-loss", "R2 inventory exceeds the supported byte range.");
    }
    cursor = page.truncated ? page.cursor ?? undefined : undefined;
    await refreshLease(reconciliationId);
    if (page.truncated && !cursor) throw new HttpsError("data-loss", "R2 pagination did not provide a continuation cursor.");
  } while (cursor);
  return { objects, totalBytes };
}

async function runReconciliation(actorUid: string, trigger: "scheduled" | "administrator"): Promise<ReconciliationResult> {
  const reconciliationId = randomUUID();
  if (!await acquireLock(reconciliationId)) return { reconciliationId, status: "busy" };

  const reportRef = db.collection("storageReconciliations").doc(reconciliationId);
  const startedAt = Timestamp.now();
  let result: ReconciliationResult;
  try {
    await reportRef.set({ reconciliationId, trigger, actorUid, status: "running", startedAt });
    const reservations = await cleanupExpiredReservations();
    if (reservations.pending > 0) {
      await setWaiting(reconciliationId, reservations.nextExpiry);
      result = { reconciliationId, status: "waiting", pendingReservationCount: reservations.pending };
      await reportRef.set({ status: "waiting", pendingReservationCount: reservations.pending, updatedAt: Timestamp.now() }, { merge: true });
      return result;
    }

    const incompleteDeletions = await retryIncompleteDeletions();
    if (incompleteDeletions > 0) {
      await setWaiting(reconciliationId);
      result = { reconciliationId, status: "waiting" };
      await reportRef.set({ status: "waiting", incompleteDeletionCount: incompleteDeletions, updatedAt: Timestamp.now() }, { merge: true });
      return result;
    }

    const inventory = await getR2Inventory(reconciliationId);
    const actualByKey = new Map(inventory.objects.map((object) => [object.key, object]));
    const ledgerByKey = new Map<string, { ref: FirebaseFirestore.DocumentReference; data: FirebaseFirestore.DocumentData }>();
    const mediaStateById = new Map<string, string>();
    await pages("mediaAssets", async (docs) => {
      for (const doc of docs) mediaStateById.set(doc.id, String(doc.data().status ?? "unknown"));
    });
    await pages("storageObjects", async (docs) => {
      for (const doc of docs) {
        const key = doc.data().objectKey;
        if (typeof key === "string") ledgerByKey.set(key, { ref: doc.ref, data: doc.data() });
      }
    });

    const missing: string[] = [];
    const orphaned: string[] = [];
    const mismatches: Array<{ key: string; recordedBytes: number; actualBytes: number }> = [];
    const operations: Array<() => Promise<unknown>> = [];
    for (const object of inventory.objects) {
      const ledger = ledgerByKey.get(object.key);
      if (!ledger) {
        orphaned.push(object.key);
        const metadata = object.customMetadata ?? {};
        const ledgerRef = objectLedgerRef(object.key);
        operations.push(() => ledgerRef.set({
          objectKey: object.key,
          sizeBytes: object.size,
          uid: metadata.uid ?? null,
          mediaType: metadata.mediaType ?? "unknown",
          reservationId: metadata.reservationId ?? null,
          accountingState: "counted",
          countedInQuota: true,
          orphaned: true,
          reconciledAt: Timestamp.now(),
          createdAt: Timestamp.now(),
          updatedAt: Timestamp.now(),
        }));
      } else if (Number(ledger.data.sizeBytes) !== object.size || ledger.data.accountingState !== "counted") {
        mismatches.push({ key: object.key, recordedBytes: Number(ledger.data.sizeBytes ?? 0), actualBytes: object.size });
        operations.push(() => ledger.ref.set({
          sizeBytes: object.size,
          accountingState: "counted",
          countedInQuota: true,
          lastReconciledAt: Timestamp.now(),
          updatedAt: Timestamp.now(),
        }, { merge: true }));
      }
      const activeLedger = ledger?.data ?? (object.customMetadata ?? {});
      const uid = activeLedger.uid;
      const assetId = activeLedger.assetId;
      if (typeof uid === "string" && typeof assetId === "string") {
        const mediaStatus = mediaStateById.get(`${uid}_${assetId}`);
        if ((!mediaStatus || ["deleted", "failed", "expired"].includes(mediaStatus)) && !orphaned.includes(object.key)) {
          orphaned.push(object.key);
          if (ledger) operations.push(() => ledger.ref.set({ orphaned: true, orphanedAt: Timestamp.now(), updatedAt: Timestamp.now() }, { merge: true }));
          else {
            const metadata = object.customMetadata ?? {};
            operations.push(() => objectLedgerRef(object.key).set({
              objectKey: object.key,
              sizeBytes: object.size,
              uid,
              assetId,
              mediaType: metadata.mediaType ?? "unknown",
              reservationId: metadata.reservationId ?? null,
              accountingState: "counted",
              countedInQuota: true,
              orphaned: true,
              orphanedAt: Timestamp.now(),
              createdAt: Timestamp.now(),
              updatedAt: Timestamp.now(),
            }));
          }
        }
      }
      if (ledger?.data.orphaned === true && !orphaned.includes(object.key)) orphaned.push(object.key);
    }
    for (const [key, ledger] of ledgerByKey) {
      if (!actualByKey.has(key) && ledger.data.accountingState === "counted") {
        missing.push(key);
        operations.push(() => ledger.ref.set({
          accountingState: "deleted",
          countedInQuota: false,
          missingFromR2At: Timestamp.now(),
          lastReconciledAt: Timestamp.now(),
          updatedAt: Timestamp.now(),
        }, { merge: true }));
      }
    }
    for (let index = 0; index < operations.length; index += 400) {
      await Promise.all(operations.slice(index, index + 400).map((operation) => operation()));
      await refreshLease(reconciliationId);
    }

    const requiresReview = missing.length > 0 || orphaned.length > 0 || mismatches.length > 0;
    const overLimit = inventory.totalBytes > R2_STORAGE_LIMIT_BYTES;
    const finalStatus = overLimit || requiresReview ? "attention" : "completed";
    const actualCountedBytes = overLimit ? undefined : inventory.totalBytes;
    const now = Timestamp.now();
    await db.runTransaction(async (transaction) => {
      const quota = await transaction.get(quotaRef);
      if (quota.data()?.reconciliationId !== reconciliationId || quota.data()?.maintenanceLock !== true) {
        throw new HttpsError("aborted", "The R2 reconciliation lock was lost.");
      }
      const oldUsed = Number(quota.data()?.usedBytes ?? 0);
      const usedBytes = actualCountedBytes ?? Math.min(oldUsed, R2_STORAGE_LIMIT_BYTES);
      const reservedBytes = 0;
      const remainingBytes = Math.max(0, R2_STORAGE_LIMIT_BYTES - usedBytes - reservedBytes);
      transaction.set(quotaRef, {
        storageProvider: "cloudflare_r2",
        limitBytes: R2_STORAGE_LIMIT_BYTES,
        usedBytes,
        reservedBytes,
        remainingBytes,
        usagePercent: ((usedBytes + reservedBytes) / R2_STORAGE_LIMIT_BYTES) * 100,
        actualBytes: inventory.totalBytes,
        uploadEnabled: !requiresReview && !overLimit,
        maintenanceLock: false,
        reconciliationState: finalStatus,
        lastReconciledAt: now,
        orphanedObjectsCount: orphaned.length,
        missingObjectsCount: missing.length,
        accountingMismatchesCount: mismatches.length,
        reconciliationId,
        updatedAt: now,
        ...(overLimit ? { overLimitBytes: inventory.totalBytes - R2_STORAGE_LIMIT_BYTES } : { overLimitBytes: 0 }),
      }, { merge: true });
      transaction.set(reportRef, {
        reconciliationId,
        trigger,
        actorUid,
        status: finalStatus,
        objectCount: inventory.objects.length,
        actualBytes: inventory.totalBytes,
        usedBytes,
        reservedBytes: 0,
        missingObjectCount: missing.length,
        orphanedObjectCount: orphaned.length,
        sizeMismatchCount: mismatches.length,
        overLimitBytes: Math.max(0, inventory.totalBytes - R2_STORAGE_LIMIT_BYTES),
        missingObjectSamples: missing.slice(0, 100),
        orphanedObjectSamples: orphaned.slice(0, 100),
        sizeMismatchSamples: mismatches.slice(0, 100),
        requiresAdministratorReview: requiresReview || overLimit,
        startedAt,
        completedAt: now,
      });
      if (requiresReview || overLimit) {
        transaction.create(db.collection("storageAudit").doc(randomUUID()), {
          action: "reconciliation.discrepancy",
          reconciliationId,
          missingObjectCount: missing.length,
          orphanedObjectCount: orphaned.length,
          sizeMismatchCount: mismatches.length,
          overLimitBytes: Math.max(0, inventory.totalBytes - R2_STORAGE_LIMIT_BYTES),
          createdAt: now,
        });
      }
    });

    result = {
      reconciliationId,
      status: finalStatus,
      objectCount: inventory.objects.length,
      actualBytes: inventory.totalBytes,
      missingObjectCount: missing.length,
      orphanedObjectCount: orphaned.length,
      sizeMismatchCount: mismatches.length,
      pendingReservationCount: 0,
    };
    if (requiresReview || overLimit) {
      logger.error("R2 reconciliation found discrepancies; uploads remain disabled", {
        missingObjectCount: missing.length,
        orphanedObjectCount: orphaned.length,
        sizeMismatchCount: mismatches.length,
        overLimit,
      });
    } else if (quotaUsageState(inventory.totalBytes, 0) !== "normal") {
      logger.warn("R2 storage usage crossed an administrator warning threshold", {
        usagePercent: (inventory.totalBytes / R2_STORAGE_LIMIT_BYTES) * 100,
      });
    }
    return result;
  } catch (error) {
    await db.runTransaction(async (transaction) => {
      const quota = await transaction.get(quotaRef);
      if (quota.data()?.reconciliationId !== reconciliationId) return;
      transaction.set(quotaRef, { uploadEnabled: false, maintenanceLock: false, reconciliationState: "failed", reconciliationErrorAt: Timestamp.now(), updatedAt: Timestamp.now() }, { merge: true });
    });
    await reportRef.set({ status: "failed", failedAt: Timestamp.now(), failureType: error instanceof Error ? error.name : "unknown" }, { merge: true });
    logger.error("R2 reconciliation failed; uploads remain disabled", { errorType: error instanceof Error ? error.name : "unknown" });
    throw error;
  }
}

export const reconcileCloudflareR2Storage = onSchedule({
  schedule: "every 15 minutes",
  timeZone: "Asia/Manila",
  region: FUNCTION_REGION,
  maxInstances: 1,
  secrets: [R2_GATEWAY_PRIVATE_JWK],
}, async () => {
  await runReconciliation("system:scheduled", "scheduled");
});

export const requestStorageReconciliation = onCall({
  region: FUNCTION_REGION,
  enforceAppCheck: enforceCallableAppCheck,
  secrets: [R2_GATEWAY_PRIVATE_JWK],
}, async (request) => {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Sign in to continue.");
  const user = await db.collection("users").doc(uid).get();
  if (user.data()?.role !== "admin") throw new HttpsError("permission-denied", "Administrator access is required.");
  return runReconciliation(uid, "administrator");
});

export const getStorageQuota = onCall({ region: FUNCTION_REGION, enforceAppCheck: enforceCallableAppCheck }, async (request) => {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Sign in to continue.");
  const user = await db.collection("users").doc(uid).get();
  if (user.data()?.role !== "admin") throw new HttpsError("permission-denied", "Administrator access is required.");

  const [quota, imageCount, awaitingPanoramaCount, countedPanoramaCount, pendingCount, failedCount, activity] = await Promise.all([
    quotaRef.get(),
    db.collection("mediaAssets").where("status", "==", "ready").where("mediaType", "in", ["product", "store"]).count().get(),
    db.collection("mediaAssets").where("status", "==", "awaiting-privacy-processing").count().get(),
    db.collection("mediaAssets").where("mediaType", "==", "panorama").where("accountingState", "==", "counted").count().get(),
    db.collection("uploadReservations").where("status", "==", "reserved").count().get(),
    db.collection("mediaAssets").where("status", "==", "failed").count().get(),
    db.collection("storageAudit").orderBy("createdAt", "desc").limit(20).get(),
  ]);
  const latestReport = await db.collection("storageReconciliations").orderBy("startedAt", "desc").limit(1).get();
  const quotaData = quota.data() ?? {};
  const serialize = (data: FirebaseFirestore.DocumentData) => Object.fromEntries(
    Object.entries(data).map(([key, value]) => [key, value instanceof Timestamp ? value.toDate().toISOString() : value]),
  );
  return {
    storageProvider: "cloudflare_r2",
    limitBytes: Number(quotaData.limitBytes ?? R2_STORAGE_LIMIT_BYTES),
    usedBytes: Number(quotaData.usedBytes ?? 0),
    reservedBytes: Number(quotaData.reservedBytes ?? 0),
    remainingBytes: Number(quotaData.remainingBytes ?? 0),
    actualBytes: Number(quotaData.actualBytes ?? 0),
    usagePercent: Number(quotaData.usagePercent ?? 0),
    state: quotaUsageState(Number(quotaData.usedBytes ?? 0), Number(quotaData.reservedBytes ?? 0)),
    uploadEnabled: quotaData.uploadEnabled === true && quotaData.maintenanceLock !== true,
    storedImages: imageCount.data().count,
    storedPanoramas: Math.max(awaitingPanoramaCount.data().count, countedPanoramaCount.data().count),
    pendingUploads: pendingCount.data().count,
    failedUploads: failedCount.data().count,
    orphanedObjects: Number(quotaData.orphanedObjectsCount ?? 0),
    missingObjects: Number(quotaData.missingObjectsCount ?? 0),
    lastReconciledAt: quotaData.lastReconciledAt instanceof Timestamp ? quotaData.lastReconciledAt.toDate().toISOString() : null,
    latestReport: latestReport.empty ? null : serialize(latestReport.docs[0].data()),
    recentActivity: activity.docs.map((doc) => ({ id: doc.id, ...serialize(doc.data()) })),
  };
});

export const deleteStorageOrphan = onCall({
  region: FUNCTION_REGION,
  enforceAppCheck: enforceCallableAppCheck,
  secrets: [R2_GATEWAY_PRIVATE_JWK],
}, async (request) => {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Sign in to continue.");
  const user = await db.collection("users").doc(uid).get();
  if (user.data()?.role !== "admin") throw new HttpsError("permission-denied", "Administrator access is required.");
  const key = request.data?.key;
  if (typeof key !== "string" || key.length > 1024 || key.startsWith("/") || key.includes("\\") ||
      key.split("/").some((part) => !part || part === "." || part === "..")) {
    throw new HttpsError("invalid-argument", "A valid R2 object key is required.");
  }
  const ledger = await objectLedgerRef(key).get();
  if (ledger.data()?.orphaned !== true || ledger.data()?.accountingState !== "counted") {
    throw new HttpsError("failed-precondition", "This object is not an active reconciliation orphan.");
  }
  await deleteStoredObject(key, uid, "administrator-orphan-cleanup");
  return { ok: true, key };
});
