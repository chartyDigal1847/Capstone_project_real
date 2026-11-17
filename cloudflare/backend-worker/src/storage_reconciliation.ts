import { documentData, FirestoreRest } from "./firestore.js";
import type { Env, Principal } from "./index.js";
import { ApiError } from "./errors.js";
import { gatewayDelete, gatewayHead, gatewayListPage } from "./r2_gateway_client.js";
import { deleteStoredObject } from "./storage_orphans.js";

const LIMIT = 9_000_000_000;
const LEASE_MS = 10 * 60 * 1000;
type Inventory = { key: string; size: number; customMetadata: Record<string, string> };

function randomId(): string { return crypto.randomUUID(); }
async function ledgerPath(key: string): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(key)));
  return `storageObjects/${Array.from(digest, (byte) => byte.toString(16).padStart(2, "0")).join("")}`;
}

async function merge(db: FirestoreRest, path: string, fields: Record<string, unknown>): Promise<void> {
  await db.runTransaction(async (tx) => {
    const old = await tx.get(path);
    if (old) tx.patch(path, fields); else tx.create(path, fields);
  });
}

function usage(used: number, reserved: number) {
  return { limitBytes: LIMIT, usedBytes: used, reservedBytes: reserved, remainingBytes: Math.max(0, LIMIT - used - reserved), usagePercent: ((used + reserved) / LIMIT) * 100 };
}

export async function releaseExpired(db: FirestoreRest, env: Env, doc: import("./firestore.js").FirestoreDocument): Promise<void> {
  const reservation = documentData(doc)!;
  const objectKey = String(reservation.objectKey ?? "");
  if (!objectKey) throw new ApiError(500, "An upload reservation has no object key.");
  const object = await gatewayHead(env, objectKey);
  if (object) {
    if (object.reservationId !== doc.name.split("/").at(-1) || object.uid !== reservation.uid || object.size > Number(reservation.reservedBytes)) {
      await gatewayDelete(env, objectKey);
    } else {
      await gatewayDelete(env, objectKey);
    }
    if (await gatewayHead(env, objectKey)) throw new ApiError(503, "An abandoned upload could not be cleaned up.");
  }
  await db.runTransaction(async (tx) => {
    const [currentDoc, quotaDoc] = await Promise.all([tx.get(doc.name.split("/documents/")[1]), tx.get("system_config/storage_quota")]);
    const current = documentData(currentDoc), quota = documentData(quotaDoc);
    if (!current || current.status !== "reserved") return;
    if (!quota || Number(quota.reservedBytes) < Number(current.reservedBytes)) throw new ApiError(500, "The R2 reservation counter is inconsistent.");
    const now = new Date(), reserved = Number(quota.reservedBytes) - Number(current.reservedBytes), used = Number(quota.usedBytes ?? 0);
    tx.patch(doc.name.split("/documents/")[1], { status: "released", releaseReason: "expired-or-abandoned", releasedAt: now, updatedAt: now });
    tx.patch("system_config/storage_quota", { ...usage(used, reserved), updatedAt: now });
    if (current.purpose === "upload") {
      const mediaPath = `mediaAssets/${current.uid}_${current.assetId}`;
      const media = await tx.get(mediaPath);
      if (media) tx.patch(mediaPath, { status: "expired", accountingState: "deleted", expiredAt: now, updatedAt: now });
      else tx.create(mediaPath, { uid: current.uid, assetId: current.assetId, mediaType: current.mediaType, status: "expired", accountingState: "deleted", expiredAt: now, updatedAt: now });
    }
  });
}

async function reconcile(db: FirestoreRest, env: Env, uid: string, trigger: "administrator" | "scheduled"): Promise<Record<string, unknown>> {
  const id = randomId(), quotaPath = "system_config/storage_quota", startedAt = new Date();
  const acquired = await db.runTransaction(async (tx) => {
    const snap = await tx.get(quotaPath), data = documentData(snap), now = new Date();
    if (data?.maintenanceLock === true && data.reconciliationLeaseUntil instanceof Date && data.reconciliationLeaseUntil.getTime() > now.getTime()) return false;
    const used = Number.isSafeInteger(data?.usedBytes) && Number(data?.usedBytes) >= 0 ? Number(data?.usedBytes) : 0;
    const reserved = Number.isSafeInteger(data?.reservedBytes) && Number(data?.reservedBytes) >= 0 ? Number(data?.reservedBytes) : 0;
    tx.set(quotaPath, { storageProvider: "cloudflare_r2", ...usage(used, reserved), uploadEnabled: false, maintenanceLock: true, reconciliationId: id, reconciliationStartedAt: data?.reconciliationStartedAt ?? now, reconciliationLeaseUntil: new Date(now.getTime() + LEASE_MS), reconciliationState: "running", updatedAt: now });
    return true;
  });
  if (!acquired) return { reconciliationId: id, status: "busy" };
  const reportPath = `storageReconciliations/${id}`;
  try {
    await db.set(reportPath, { reconciliationId: id, trigger, actorUid: uid, status: "running", startedAt });
    const reservationDocs = await db.listAll("uploadReservations");
    const now = Date.now(), expired: typeof reservationDocs = [], pending: typeof reservationDocs = [];
    for (const doc of reservationDocs) {
      const data = documentData(doc)!;
      if (data.status !== "reserved") continue;
      if (data.expiresAt instanceof Date && data.expiresAt.getTime() <= now) expired.push(doc); else pending.push(doc);
    }
    for (const doc of expired) await releaseExpired(db, env, doc);
    if (pending.length) {
      const expiry = pending.map((doc) => documentData(doc)!.expiresAt).filter((date): date is Date => date instanceof Date).sort((a, b) => a.getTime() - b.getTime())[0];
      await db.runTransaction(async (tx) => {
        const quota = documentData(await tx.get(quotaPath));
        if (quota?.reconciliationId !== id) return;
        tx.patch(quotaPath, { uploadEnabled: false, maintenanceLock: true, reconciliationState: "waiting-for-active-operations", reconciliationLeaseUntil: expiry && expiry.getTime() > Date.now() ? expiry : new Date(Date.now() + LEASE_MS), updatedAt: new Date() });
      });
      const result = { reconciliationId: id, status: "waiting", pendingReservationCount: pending.length };
      await merge(db, reportPath, { status: "waiting", pendingReservationCount: pending.length, updatedAt: new Date() });
      return result;
    }

    const deleting = (await db.listAll("storageObjects")).filter((doc) => documentData(doc)?.accountingState === "deleting");
    if (deleting.length) {
      for (const doc of deleting) {
        const key = documentData(doc)?.objectKey;
        if (typeof key === "string") await deleteStoredObject(db, env, key, "system:reconciliation", "incomplete-deletion-retry");
      }
      await db.runTransaction(async (tx) => {
        const quota = documentData(await tx.get(quotaPath));
        if (quota?.reconciliationId === id) tx.patch(quotaPath, { uploadEnabled: false, maintenanceLock: true, reconciliationState: "waiting-for-active-operations", reconciliationLeaseUntil: new Date(Date.now() + LEASE_MS), updatedAt: new Date() });
      });
      await merge(db, reportPath, { status: "waiting", incompleteDeletionCount: deleting.length, updatedAt: new Date() });
      return { reconciliationId: id, status: "waiting" };
    }

    const objects: Inventory[] = [];
    let cursor: string | undefined, totalBytes = 0;
    do {
      const page = await gatewayListPage(env, cursor, 1000);
      for (const object of page.objects) {
        if (typeof object.key !== "string" || !Number.isSafeInteger(object.size) || object.size < 0) throw new ApiError(502, "R2 returned invalid object metadata.");
        objects.push({ key: object.key, size: object.size, customMetadata: object.customMetadata ?? {} }); totalBytes += object.size;
        if (!Number.isSafeInteger(totalBytes)) throw new ApiError(502, "R2 inventory exceeds the supported byte range.");
      }
      cursor = page.truncated ? page.cursor ?? undefined : undefined;
      if (page.truncated && !cursor) throw new ApiError(502, "R2 pagination did not provide a continuation cursor.");
      await db.runTransaction(async (tx) => {
        const quota = documentData(await tx.get(quotaPath));
        if (quota?.reconciliationId !== id || quota.maintenanceLock !== true) throw new ApiError(409, "The R2 reconciliation lock was lost.");
        tx.patch(quotaPath, { reconciliationLeaseUntil: new Date(Date.now() + LEASE_MS), updatedAt: new Date() });
      });
    } while (cursor);

    const [mediaDocs, ledgerDocs] = await Promise.all([db.listAll("mediaAssets"), db.listAll("storageObjects")]);
    const mediaStates = new Map(mediaDocs.map((doc) => [doc.name.split("/").at(-1)!, String(documentData(doc)?.status ?? "unknown")]));
    const ledgerByKey = new Map(ledgerDocs.flatMap((doc) => { const data = documentData(doc)!; return typeof data.objectKey === "string" ? [[data.objectKey, { path: doc.name.split("/documents/")[1], data }] as const] : []; }));
    const actualByKey = new Map(objects.map((object) => [object.key, object]));
    const missing: string[] = [], orphaned = new Set<string>(), mismatches: Array<{ key: string; recordedBytes: number; actualBytes: number }> = [];
    for (const object of objects) {
      const ledger = ledgerByKey.get(object.key), metadata = object.customMetadata ?? {};
      if (!ledger) {
        orphaned.add(object.key);
        await db.runTransaction(async (tx) => {
          const path = await ledgerPath(object.key), current = await tx.get(path), fields = { objectKey: object.key, sizeBytes: object.size, uid: metadata.uid ?? null, assetId: metadata.assetId ?? null, mediaType: metadata.mediaType ?? "unknown", reservationId: metadata.reservationId ?? null, accountingState: "counted", countedInQuota: true, orphaned: true, reconciledAt: new Date(), createdAt: new Date(), updatedAt: new Date() };
          if (current) tx.patch(path, { ...fields, createdAt: documentData(current)?.createdAt ?? new Date() }); else tx.create(path, fields);
        });
      } else if (Number(ledger.data.sizeBytes) !== object.size || ledger.data.accountingState !== "counted") {
        mismatches.push({ key: object.key, recordedBytes: Number(ledger.data.sizeBytes ?? 0), actualBytes: object.size });
        await merge(db, ledger.path, { sizeBytes: object.size, accountingState: "counted", countedInQuota: true, lastReconciledAt: new Date(), updatedAt: new Date() });
      }
      const uidValue = ledger?.data.uid ?? metadata.uid, assetIdValue = ledger?.data.assetId ?? metadata.assetId;
      if (typeof uidValue === "string" && typeof assetIdValue === "string") {
        const mediaStatus = mediaStates.get(`${uidValue}_${assetIdValue}`);
        if ((!mediaStatus || ["deleted", "failed", "expired"].includes(mediaStatus)) && !orphaned.has(object.key)) {
          orphaned.add(object.key);
          const path = ledger?.path ?? await ledgerPath(object.key);
          await merge(db, path, { objectKey: object.key, sizeBytes: object.size, uid: uidValue, assetId: assetIdValue, mediaType: metadata.mediaType ?? "unknown", reservationId: metadata.reservationId ?? null, accountingState: "counted", countedInQuota: true, orphaned: true, orphanedAt: new Date(), updatedAt: new Date() });
        }
      }
      if (ledger?.data.orphaned === true) orphaned.add(object.key);
    }
    for (const [key, ledger] of ledgerByKey) if (!actualByKey.has(key) && ledger.data.accountingState === "counted") {
      missing.push(key);
      await merge(db, ledger.path, { accountingState: "deleted", countedInQuota: false, missingFromR2At: new Date(), lastReconciledAt: new Date(), updatedAt: new Date() });
    }
    const needsReview = missing.length > 0 || orphaned.size > 0 || mismatches.length > 0, overLimit = totalBytes > LIMIT;
    const finalState = overLimit || needsReview ? "attention" : "completed", usedBytes = overLimit ? Math.min(Number(documentData(await db.get(quotaPath))?.usedBytes ?? 0), LIMIT) : totalBytes;
    const completedAt = new Date();
    await db.runTransaction(async (tx) => {
      const quota = documentData(await tx.get(quotaPath));
      if (quota?.reconciliationId !== id || quota.maintenanceLock !== true) throw new ApiError(409, "The R2 reconciliation lock was lost.");
      tx.patch(quotaPath, { storageProvider: "cloudflare_r2", ...usage(usedBytes, 0), actualBytes: totalBytes, uploadEnabled: !needsReview && !overLimit, maintenanceLock: false, reconciliationState: finalState, lastReconciledAt: completedAt, orphanedObjectsCount: orphaned.size, missingObjectsCount: missing.length, accountingMismatchesCount: mismatches.length, reconciliationId: id, updatedAt: completedAt, overLimitBytes: Math.max(0, totalBytes - LIMIT) });
      tx.set(reportPath, { reconciliationId: id, trigger, actorUid: uid, status: finalState, objectCount: objects.length, actualBytes: totalBytes, usedBytes, reservedBytes: 0, missingObjectCount: missing.length, orphanedObjectCount: orphaned.size, sizeMismatchCount: mismatches.length, overLimitBytes: Math.max(0, totalBytes - LIMIT), missingObjectSamples: missing.slice(0, 100), orphanedObjectSamples: [...orphaned].slice(0, 100), sizeMismatchSamples: mismatches.slice(0, 100), requiresAdministratorReview: needsReview || overLimit, startedAt, completedAt });
      if (needsReview || overLimit) tx.create(`storageAudit/${randomId()}`, { action: "reconciliation.discrepancy", reconciliationId: id, missingObjectCount: missing.length, orphanedObjectCount: orphaned.size, sizeMismatchCount: mismatches.length, overLimitBytes: Math.max(0, totalBytes - LIMIT), createdAt: completedAt });
    });
    return { reconciliationId: id, status: finalState, objectCount: objects.length, actualBytes: totalBytes, missingObjectCount: missing.length, orphanedObjectCount: orphaned.size, sizeMismatchCount: mismatches.length, pendingReservationCount: 0 };
  } catch (error) {
    await db.runTransaction(async (tx) => {
      const quota = documentData(await tx.get(quotaPath));
      if (quota?.reconciliationId === id) tx.patch(quotaPath, { uploadEnabled: false, maintenanceLock: false, reconciliationState: "failed", reconciliationErrorAt: new Date(), updatedAt: new Date() });
    });
    await merge(db, reportPath, { status: "failed", failedAt: new Date(), failureType: error instanceof Error ? error.name : "unknown" });
    throw error;
  }
}

export async function handleStorageReconciliation(request: Request, env: Env, principal: Principal): Promise<Response> {
  if (request.method !== "POST") return Response.json({ error: "Method not allowed." }, { status: 405, headers: { Allow: "POST" } });
  const profile = documentData(await new FirestoreRest(env).get(`users/${principal.uid}`));
  if (profile?.role !== "admin") throw new ApiError(403, "Administrator access is required.");
  const result = await reconcile(new FirestoreRest(env), env, principal.uid, "administrator");
  return Response.json(result, { headers: { "Cache-Control": "no-store" } });
}

export async function runScheduledReconciliation(env: Env): Promise<void> {
  await reconcile(new FirestoreRest(env), env, "system:scheduled", "scheduled");
}
