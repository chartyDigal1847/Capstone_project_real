import { documentData, FirestoreRest } from "./firestore.js";
import type { Env, Principal } from "./index.js";
import { ApiError } from "./errors.js";
import { gatewayDelete, gatewayHead } from "./r2_gateway_client.js";

async function body(request: Request): Promise<Record<string, unknown>> {
  try { const value: unknown = await request.json(); if (value && typeof value === "object" && !Array.isArray(value)) return value as Record<string, unknown>; }
  catch { /* bad JSON */ }
  throw new ApiError(400, "A valid JSON object is required.");
}

async function ledgerPath(key: string): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(key)));
  return `storageObjects/${Array.from(digest, (byte) => byte.toString(16).padStart(2, "0")).join("")}`;
}

function auditId(): string { return crypto.randomUUID(); }

export async function deleteStoredObject(db: FirestoreRest, env: Env, key: string, actor: string, reason = "administrator-orphan-cleanup", requireOrphan = false): Promise<void> {
  const path = await ledgerPath(key);
  const initial = documentData(await db.get(path));
  if (!initial) {
    const observed = await gatewayHead(env, key);
    await db.runTransaction(async (tx) => {
      const [current, quotaDoc] = await Promise.all([tx.get(path), tx.get("system_config/storage_quota")]);
      if (documentData(current)) throw new ApiError(409, "The storage ledger changed while deletion was being prepared.");
      if (documentData(quotaDoc)?.maintenanceLock === true && !actor.startsWith("system:")) throw new ApiError(503, "Storage maintenance is in progress. Retry shortly.");
      tx.create(path, { objectKey: key, sizeBytes: observed?.size ?? 0, accountingState: "deleting", countedInQuota: false, createdAt: new Date(), updatedAt: new Date() });
    });
    const result = await gatewayDelete(env, key);
    if (await gatewayHead(env, key)) throw new ApiError(503, "R2 has not confirmed that the object is gone.");
    await db.runTransaction(async (tx) => {
      const current = documentData(await tx.get(path));
      if (!current || current.accountingState === "deleted") return;
      const now = new Date();
      tx.patch(path, { accountingState: "deleted", countedInQuota: false, deletedAt: now, deletionActorUid: actor, deletionWasAlreadyMissing: !result.existed, updatedAt: now });
      tx.create(`storageAudit/${auditId()}`, { action: "object.deleted", objectKey: key, sizeBytes: Number(current.sizeBytes ?? 0), actorUid: actor, reason, createdAt: now });
    });
    return;
  }
  if (initial.accountingState === "deleted") return;
  const shouldDelete = await db.runTransaction(async (tx) => {
    const [current, quotaDoc] = await Promise.all([tx.get(path), tx.get("system_config/storage_quota")]);
    const latest = documentData(current);
    if (!latest || latest.accountingState === "deleted") return false;
    if (requireOrphan && (latest.orphaned !== true || latest.accountingState !== "counted")) throw new ApiError(412, "This object is no longer an active reconciliation orphan.");
    if (documentData(quotaDoc)?.maintenanceLock === true && !actor.startsWith("system:")) throw new ApiError(503, "Storage maintenance is in progress. Retry shortly.");
    tx.patch(path, { accountingState: "deleting", deletionReason: reason, deletionStartedAt: new Date() });
    return true;
  });
  if (!shouldDelete) return;
  const result = await gatewayDelete(env, key);
  if (await gatewayHead(env, key)) throw new ApiError(503, "R2 has not confirmed that the object is gone.");
  await db.runTransaction(async (tx) => {
    const [ledgerDoc, quotaDoc] = await Promise.all([tx.get(path), tx.get("system_config/storage_quota")]);
    const ledger = documentData(ledgerDoc);
    if (!ledger || ledger.accountingState === "deleted") return;
    const size = Number(ledger.sizeBytes);
    const quota = documentData(quotaDoc);
    const counted = ledger.countedInQuota !== false;
    if (!Number.isSafeInteger(size) || size < 0 || (counted && (!quota || Number(quota.usedBytes) < size))) throw new ApiError(500, "R2 storage accounting cannot safely apply this deletion.");
    const now = new Date();
    tx.patch(path, { accountingState: "deleted", countedInQuota: false, deletedAt: now, deletionActorUid: actor, deletionReason: reason, deletionWasAlreadyMissing: !result.existed, updatedAt: now });
    if (counted) {
      const usedBytes = Number(quota!.usedBytes) - size;
      const reservedBytes = Number(quota!.reservedBytes ?? 0);
      const limitBytes = Number(quota!.limitBytes ?? 9_000_000_000);
      tx.patch("system_config/storage_quota", { usedBytes, reservedBytes, remainingBytes: limitBytes - usedBytes - reservedBytes, usagePercent: ((usedBytes + reservedBytes) / limitBytes) * 100, updatedAt: now });
    }
    tx.create(`storageAudit/${auditId()}`, { action: "object.deleted", objectKey: key, sizeBytes: counted ? size : 0, actorUid: actor, reason, createdAt: now });
  });
}

export async function handleStorageOrphanDelete(request: Request, env: Env, principal: Principal): Promise<Response> {
  if (request.method !== "POST") return Response.json({ error: "Method not allowed." }, { status: 405, headers: { Allow: "POST" } });
  const db = new FirestoreRest(env);
  const profile = documentData(await db.get(`users/${principal.uid}`));
  if (profile?.role !== "admin") throw new ApiError(403, "Administrator access is required.");
  const { key } = await body(request);
  if (typeof key !== "string" || key.length > 1024 || key.startsWith("/") || key.includes("\\") || key.split("/").some((part) => !part || part === "." || part === "..")) {
    throw new ApiError(400, "A valid R2 object key is required.");
  }
  const ledger = documentData(await db.get(await ledgerPath(key)));
  if (ledger?.orphaned !== true || ledger.accountingState !== "counted") throw new ApiError(412, "This object is not an active reconciliation orphan.");
  await deleteStoredObject(db, env, key, principal.uid, "administrator-orphan-cleanup", true);
  return Response.json({ ok: true, key }, { headers: { "Cache-Control": "no-store" } });
}
