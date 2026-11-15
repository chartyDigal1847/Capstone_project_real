import { createHash, randomUUID } from "node:crypto";
import { Timestamp, type DocumentReference } from "firebase-admin/firestore";
import { HttpsError } from "firebase-functions/v2/https";
import { db } from "./admin";
import { r2Delete, r2Head } from "./r2_gateway";

export const R2_STORAGE_LIMIT_BYTES = 9_000_000_000;
export const R2_WARNING_THRESHOLD = 0.8;
export const R2_CRITICAL_THRESHOLD = 0.9;
export const UPLOAD_TOKEN_TTL_MS = 5 * 60 * 1000;
export const UPLOAD_IN_FLIGHT_GRACE_MS = 5 * 60 * 1000;

export interface NewReservation {
  reservationId?: string;
  uid: string;
  assetId: string;
  mediaType: "product" | "store" | "panorama";
  objectKey: string;
  reservedBytes: number;
  purpose?: "upload" | "processed" | "published";
  tourId?: number;
}

export const quotaRef = db.collection("system_config").doc("storage_quota");

export function objectLedgerRef(objectKey: string): DocumentReference {
  const id = createHash("sha256").update(objectKey).digest("hex");
  return db.collection("storageObjects").doc(id);
}

function validByteCount(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0;
}

function valuesFor(usedBytes: number, reservedBytes: number, now: Timestamp) {
  const limitBytes = R2_STORAGE_LIMIT_BYTES;
  const remainingBytes = limitBytes - usedBytes - reservedBytes;
  return {
    limitBytes,
    usedBytes,
    reservedBytes,
    remainingBytes,
    usagePercent: ((usedBytes + reservedBytes) / limitBytes) * 100,
    updatedAt: now,
  };
}

function readQuota(data: FirebaseFirestore.DocumentData | undefined): { usedBytes: number; reservedBytes: number } {
  if (!data || data.storageProvider !== "cloudflare_r2" || data.limitBytes !== R2_STORAGE_LIMIT_BYTES ||
      !validByteCount(data.usedBytes) || !validByteCount(data.reservedBytes) ||
      data.usedBytes + data.reservedBytes > R2_STORAGE_LIMIT_BYTES) {
    throw new HttpsError("failed-precondition", "R2 storage accounting is not initialized or is inconsistent. Uploads are paused until an administrator reconciles storage.");
  }
  if (data.uploadEnabled !== true || data.maintenanceLock === true) {
    throw new HttpsError("resource-exhausted", "R2 uploads are temporarily paused while storage is checked.");
  }
  return { usedBytes: data.usedBytes, reservedBytes: data.reservedBytes };
}

export async function reserveStorageBytes(input: NewReservation, expiresAt: Timestamp): Promise<string> {
  if (!validByteCount(input.reservedBytes) || input.reservedBytes <= 0 || input.reservedBytes > R2_STORAGE_LIMIT_BYTES) {
    throw new HttpsError("invalid-argument", "The requested storage reservation is invalid.");
  }
  const reservationId = input.reservationId ?? randomUUID();
  const reservationRef = db.collection("uploadReservations").doc(reservationId);
  const mediaRef = db.collection("mediaAssets").doc(`${input.uid}_${input.assetId}`);
  const now = Timestamp.now();
  await db.runTransaction(async (transaction) => {
    const [quota, existingReservation, media] = await Promise.all([
      transaction.get(quotaRef),
      transaction.get(reservationRef),
      transaction.get(mediaRef),
    ]);
    if (existingReservation.exists) throw new HttpsError("already-exists", "This upload reservation already exists.");
    if ((input.purpose ?? "upload") === "upload" && media.exists) {
      throw new HttpsError("already-exists", "This media ID has already been used.");
    }
    const { usedBytes, reservedBytes } = readQuota(quota.data());
    if (usedBytes + reservedBytes + input.reservedBytes > R2_STORAGE_LIMIT_BYTES) {
      throw new HttpsError("resource-exhausted", "STORAGE_LIMIT_REACHED");
    }
    transaction.create(reservationRef, {
      reservationId,
      uid: input.uid,
      assetId: input.assetId,
      mediaType: input.mediaType,
      objectKey: input.objectKey,
      reservedBytes: input.reservedBytes,
      purpose: input.purpose ?? "upload",
      ...(input.tourId ? { tourId: input.tourId } : {}),
      status: "reserved",
      createdAt: now,
      expiresAt,
    });
    if ((input.purpose ?? "upload") === "upload") {
      transaction.create(mediaRef, {
        uid: input.uid,
        assetId: input.assetId,
        mediaType: input.mediaType,
        status: "uploading",
        reservationId,
        objectKey: input.objectKey,
        ...(input.tourId ? { tourId: input.tourId } : {}),
        size: 0,
        accountingState: "reserved",
        createdAt: now,
        updatedAt: now,
      });
    }
    const nextValues = valuesFor(usedBytes, reservedBytes + input.reservedBytes, now);
    const beforeState = quotaUsageState(usedBytes, reservedBytes);
    const afterState = quotaUsageState(usedBytes, reservedBytes + input.reservedBytes);
    if (beforeState === "normal" && afterState !== "normal") {
      transaction.create(db.collection("storageAudit").doc(randomUUID()), {
        action: afterState === "warning" ? "quota.warning" : "quota.critical",
        state: afterState,
        usagePercent: nextValues.usagePercent,
        reservedBytes: input.reservedBytes,
        createdAt: now,
      });
    } else if (beforeState === "warning" && ["critical", "full"].includes(afterState)) {
      transaction.create(db.collection("storageAudit").doc(randomUUID()), {
        action: afterState === "full" ? "quota.full" : "quota.critical",
        state: afterState,
        usagePercent: nextValues.usagePercent,
        reservedBytes: input.reservedBytes,
        createdAt: now,
      });
    }
    transaction.update(quotaRef, nextValues);
  });
  return reservationId;
}

export async function completeStorageReservation(
  reservationId: string,
  actualBytes: number,
  mediaUpdate?: Record<string, unknown>,
): Promise<void> {
  if (!validByteCount(actualBytes) || actualBytes <= 0) throw new HttpsError("data-loss", "R2 returned an invalid object size.");
  const reservationRef = db.collection("uploadReservations").doc(reservationId);
  await db.runTransaction(async (transaction) => {
    const reservation = await transaction.get(reservationRef);
    if (!reservation.exists) throw new HttpsError("not-found", "The upload reservation was not found.");
    const data = reservation.data()!;
    const ledgerRef = objectLedgerRef(String(data.objectKey));
    const mediaRef = db.collection("mediaAssets").doc(`${data.uid}_${data.assetId}`);
    const [quota, ledger, media] = await Promise.all([
      transaction.get(quotaRef),
      transaction.get(ledgerRef),
      transaction.get(mediaRef),
    ]);
    const quotaData = quota.data();
    if (!quota.exists || !quotaData || !validByteCount(quotaData.usedBytes) || !validByteCount(quotaData.reservedBytes)) {
      throw new HttpsError("failed-precondition", "R2 storage accounting is not available.");
    }
    if (data.status === "completed") {
      if (Number(data.actualBytes) !== actualBytes || ledger.data()?.accountingState !== "counted") {
        throw new HttpsError("data-loss", "The completed upload does not match its storage record.");
      }
      return;
    }
    if (data.status !== "reserved" || actualBytes > Number(data.reservedBytes)) {
      throw new HttpsError("resource-exhausted", "The actual upload size exceeds its reservation.");
    }
    if (ledger.exists) throw new HttpsError("already-exists", "This object is already included in storage accounting.");
    const nextUsed = Number(quotaData.usedBytes) + actualBytes;
    const nextReserved = Number(quotaData.reservedBytes) - Number(data.reservedBytes);
    if (nextReserved < 0 || nextUsed + nextReserved > R2_STORAGE_LIMIT_BYTES) {
      throw new HttpsError("data-loss", "R2 storage accounting would exceed its configured limit.");
    }
    const now = Timestamp.now();
    transaction.create(ledgerRef, {
      objectKey: data.objectKey,
      sizeBytes: actualBytes,
      uid: data.uid,
      assetId: data.assetId,
      mediaType: data.mediaType,
      reservationId,
      accountingState: "counted",
      countedInQuota: true,
      createdAt: now,
      updatedAt: now,
    });
    transaction.update(reservationRef, { status: "completed", actualBytes, completedAt: now, updatedAt: now });
    if (mediaUpdate) {
      if (!media.exists) throw new HttpsError("not-found", "Media metadata was not found.");
      transaction.update(mediaRef, { ...mediaUpdate, updatedAt: now });
    }
    transaction.update(quotaRef, valuesFor(nextUsed, nextReserved, now));
    transaction.create(db.collection("storageAudit").doc(randomUUID()), {
      action: "object.uploaded",
      objectKey: data.objectKey,
      sizeBytes: actualBytes,
      uid: data.uid,
      assetId: data.assetId,
      mediaType: data.mediaType,
      reservationId,
      createdAt: now,
    });
  });
}

export async function releaseStorageReservation(reservationId: string, reason: string): Promise<void> {
  const reservationRef = db.collection("uploadReservations").doc(reservationId);
  await db.runTransaction(async (transaction) => {
    const reservation = await transaction.get(reservationRef);
    if (!reservation.exists) return;
    const data = reservation.data()!;
    if (data.status === "released") return;
    if (data.status !== "reserved") throw new HttpsError("failed-precondition", "A completed reservation must be released by deleting its stored object.");
    const quota = await transaction.get(quotaRef);
    const quotaData = quota.data();
    if (!quota.exists || !quotaData || Number(quotaData.reservedBytes) < Number(data.reservedBytes)) {
      throw new HttpsError("data-loss", "The R2 reservation counter is inconsistent.");
    }
    const now = Timestamp.now();
    transaction.update(reservationRef, { status: "released", releaseReason: reason, releasedAt: now, updatedAt: now });
    transaction.update(quotaRef, valuesFor(Number(quotaData.usedBytes), Number(quotaData.reservedBytes) - Number(data.reservedBytes), now));
  });
}

export async function deleteStoredObject(objectKey: string, actorUid: string, reason: string): Promise<{ sizeBytes: number; existed: boolean }> {
  const ledgerRef = objectLedgerRef(objectKey);
  const initialLedger = await ledgerRef.get();
  if (!initialLedger.exists) {
    const observed = await r2Head(objectKey);
    await db.runTransaction(async (transaction) => {
      const [current, quota] = await Promise.all([transaction.get(ledgerRef), transaction.get(quotaRef)]);
      if (current.exists) return;
      if (quota.data()?.maintenanceLock === true && !actorUid.startsWith("system:")) {
        throw new HttpsError("unavailable", "Storage maintenance is in progress. Retry the deletion shortly.");
      }
      const now = Timestamp.now();
      transaction.create(ledgerRef, {
        objectKey,
        sizeBytes: observed?.size ?? 0,
        accountingState: "deleting",
        countedInQuota: false,
        createdAt: now,
        updatedAt: now,
        deletionReason: reason,
      });
    });
    const deletion = await r2Delete(objectKey);
    if (await r2Head(objectKey)) throw new HttpsError("unavailable", "R2 has not confirmed that the object is gone.");
    await db.runTransaction(async (transaction) => {
      const current = await transaction.get(ledgerRef);
      if (!current.exists || current.data()?.accountingState === "deleted") return;
      const now = Timestamp.now();
      transaction.update(ledgerRef, { accountingState: "deleted", countedInQuota: false, deletedAt: now, deletionActorUid: actorUid, updatedAt: now });
      transaction.create(db.collection("storageAudit").doc(randomUUID()), {
        action: "object.deleted",
        objectKey,
        sizeBytes: Number(current.data()?.sizeBytes ?? 0),
        actorUid,
        reason,
        createdAt: now,
      });
    });
    return { sizeBytes: observed?.size ?? 0, existed: deletion.existed };
  }
  const initial = initialLedger.data()!;
  if (initial.accountingState === "deleted") return { sizeBytes: Number(initial.sizeBytes), existed: false };

  await db.runTransaction(async (transaction) => {
    const [current, quota] = await Promise.all([transaction.get(ledgerRef), transaction.get(quotaRef)]);
    if (!current.exists || current.data()?.accountingState === "deleted") return;
    if (quota.data()?.maintenanceLock === true && !actorUid.startsWith("system:")) {
      throw new HttpsError("unavailable", "Storage maintenance is in progress. Retry the deletion shortly.");
    }
    transaction.update(ledgerRef, { accountingState: "deleting", deletionReason: reason, deletionStartedAt: Timestamp.now() });
  });

  const deletion = await r2Delete(objectKey);
  if ((await r2Head(objectKey)) != null) throw new HttpsError("unavailable", "R2 has not confirmed that the object is gone.");

  await db.runTransaction(async (transaction) => {
    const [ledger, quota] = await Promise.all([transaction.get(ledgerRef), transaction.get(quotaRef)]);
    if (!ledger.exists || ledger.data()?.accountingState === "deleted") return;
    const sizeBytes = Number(ledger.data()?.sizeBytes);
    const quotaData = quota.data();
    const countedInQuota = ledger.data()?.countedInQuota !== false;
    if (!validByteCount(sizeBytes) || !quota.exists || !quotaData || (countedInQuota && Number(quotaData.usedBytes) < sizeBytes)) {
      throw new HttpsError("data-loss", "R2 storage accounting cannot safely apply this deletion.");
    }
    const now = Timestamp.now();
    transaction.update(ledgerRef, {
      accountingState: "deleted",
      countedInQuota: false,
      deletedAt: now,
      deletionActorUid: actorUid,
      deletionReason: reason,
      deletionWasAlreadyMissing: !deletion.existed,
      updatedAt: now,
    });
    if (countedInQuota) transaction.update(quotaRef, valuesFor(Number(quotaData.usedBytes) - sizeBytes, Number(quotaData.reservedBytes), now));
    transaction.create(db.collection("storageAudit").doc(randomUUID()), {
      action: "object.deleted",
      objectKey,
      sizeBytes: countedInQuota ? sizeBytes : 0,
      actorUid,
      reason,
      createdAt: now,
    });
  });
  return { sizeBytes: Number(initial.sizeBytes), existed: deletion.existed };
}

export async function releaseExpiredReservation(reservationId: string): Promise<void> {
  const ref = db.collection("uploadReservations").doc(reservationId);
  const snapshot = await ref.get();
  if (!snapshot.exists || snapshot.data()?.status !== "reserved") return;
  const reservation = snapshot.data()!;
  const expiresAt = reservation.expiresAt;
  if (!(expiresAt instanceof Timestamp) || expiresAt.toMillis() > Date.now()) return;

  const object = await r2Head(String(reservation.objectKey));
  if (object && object.size <= Number(reservation.reservedBytes) &&
      object.reservationId === reservationId && object.uid === reservation.uid) {
    await r2Delete(object.key);
    if ((await r2Head(object.key)) != null) throw new HttpsError("unavailable", "An abandoned upload could not be cleaned up.");
  } else if (object) {
    await r2Delete(object.key);
    if ((await r2Head(object.key)) != null) throw new HttpsError("unavailable", "An invalid upload could not be cleaned up.");
  }
  await releaseStorageReservation(reservationId, "expired-or-abandoned");
}

export function quotaUsageState(usedBytes: number, reservedBytes: number, limitBytes = R2_STORAGE_LIMIT_BYTES): "normal" | "warning" | "critical" | "full" {
  const ratio = (usedBytes + reservedBytes) / limitBytes;
  if (ratio >= 1) return "full";
  if (ratio >= R2_CRITICAL_THRESHOLD) return "critical";
  if (ratio >= R2_WARNING_THRESHOLD) return "warning";
  return "normal";
}
