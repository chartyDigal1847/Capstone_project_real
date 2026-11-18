import { documentData, FirestoreRest } from "./firestore.js";
import type { Env, Principal } from "./index.js";
import { ApiError } from "./errors.js";
import { gatewayBase, gatewayHead, signUploadCapability } from "./r2_gateway_client.js";

const LIMIT = 9_000_000_000, MAX_PANORAMA_BYTES = 50 * 1024 * 1024;

async function body(request: Request): Promise<Record<string, unknown>> {
  try { const value: unknown = await request.json(); if (value && typeof value === "object" && !Array.isArray(value)) return value as Record<string, unknown>; }
  catch { /* invalid JSON */ }
  throw new ApiError(400, "A valid JSON object is required.");
}

async function rateLimit(db: FirestoreRest, uid: string): Promise<void> {
  await db.runTransaction(async (tx) => {
    const path = `systemRateLimits/${uid}_panoramaDerivativeUpload`, current = documentData(await tx.get(path));
    const now = new Date(), start = current?.windowStartedAt instanceof Date ? current.windowStartedAt : null;
    const elapsed = start ? now.getTime() - start.getTime() : null, active = elapsed !== null && elapsed >= 0 && elapsed < 3_600_000;
    const count = active ? Number(current?.count ?? 0) : 0;
    if (count >= 20) throw new ApiError(429, "You have reached the panorama derivative upload limit.");
    tx.set(path, { uid, operation: "panoramaDerivativeUpload", windowStartedAt: active ? start! : now, count: count + 1, updatedAt: now });
  });
}

export async function reservePanoramaDerivativeUpload(request: Request, env: Env, principal: Principal): Promise<Response> {
  if (request.method !== "POST") return Response.json({ error: "Method not allowed." }, { status: 405, headers: { Allow: "POST" } });
  const data = await body(request), uid = principal.uid;
  if (!Number.isSafeInteger(data.tourId) || Number(data.tourId) <= 0 || !Number.isSafeInteger(data.nodeId) || Number(data.nodeId) <= 0) throw new ApiError(400, "Valid tour and viewpoint IDs are required.");
  if (typeof data.assetId !== "string" || !/^[A-Za-z0-9_-]{1,100}$/.test(data.assetId)) throw new ApiError(400, "A valid original panorama media ID is required.");
  if (data.contentType !== "image/jpeg") throw new ApiError(400, "Panorama derivatives must be JPEG images.");
  if (!Number.isSafeInteger(data.expectedBytes) || Number(data.expectedBytes) <= 0 || Number(data.expectedBytes) > MAX_PANORAMA_BYTES) throw new ApiError(400, "The derivative must be no larger than 50 MiB.");
  if (typeof data.derivativeSha256 !== "string" || !/^[a-f0-9]{64}$/.test(data.derivativeSha256)) throw new ApiError(400, "A lowercase derivative SHA-256 digest is required.");
  if (typeof data.processingVersion !== "string" || !/^(?:localspot-panorama-local-v[0-9]{1,8}|localspot-panorama-original-v1)$/.test(data.processingVersion)) throw new ApiError(400, "The panorama processing version is invalid.");
  const tourId = Number(data.tourId), nodeId = Number(data.nodeId), db = new FirestoreRest(env);
  const tours = await db.query("tours", [{ field: "numericId", op: "EQUAL", value: tourId }], 1);
  if (!tours.length) throw new ApiError(404, "Tour was not found.");
  const tour = documentData(tours[0])!;
  const stores = await db.query("stores", [{ field: "numericId", op: "EQUAL", value: Number(tour.storeId) }], 1);
  if (!stores.length) throw new ApiError(404, "Store was not found.");
  const store = documentData(stores[0])!;
  if (tour.status !== "draft" || tour.ownerUid !== uid || store.ownerUid !== uid || store.status !== "approved") throw new ApiError(403, "Only the authenticated owner can add a derivative to this draft tour.");
  const node = (Array.isArray(tour.nodes) ? tour.nodes as Array<Record<string, unknown>> : []).find((row) => Number(row.id) === nodeId);
  const originalPath = node?.original_path;
  if (!node || typeof originalPath !== "string" || !originalPath.startsWith(`tours/originals/${uid}/${tourId}/`)) throw new ApiError(404, "The owner panorama viewpoint was not found.");
  const media = documentData(await db.get(`mediaAssets/${uid}_${data.assetId}`));
  if (!media || media.uid !== uid || media.mediaType !== "panorama" || media.originalPath !== originalPath || media.linkedTourId !== tourId || !["awaiting-privacy-processing", "privacy-derivative-ready"].includes(String(media.status))) throw new ApiError(412, "The original panorama is not linked to this owner viewpoint.");
  const original = await gatewayHead(env, originalPath);
  if (!original || original.key !== originalPath || original.uid !== uid || original.mediaType !== "panorama" || original.contentType !== "image/jpeg" || original.size <= 0 || original.size > MAX_PANORAMA_BYTES) throw new ApiError(412, "The private original JPEG could not be verified.");
  await rateLimit(db, uid);
  const revisionId = crypto.randomUUID().replace(/-/g, ""), reservationId = crypto.randomUUID();
  const objectKey = `tours/derivatives/${uid}/${tourId}/${nodeId}/${revisionId}_${data.derivativeSha256}.jpg`;
  const now = new Date(), tokenExpiry = new Date(now.getTime() + 5 * 60_000), expiresAt = new Date(tokenExpiry.getTime() + 5 * 60_000);
  const uploadUrl = `${gatewayBase(env)}/v1/uploads/${encodeURIComponent(reservationId)}`;
  const uploadToken = await signUploadCapability(env, { scope: "upload", objectKey, contentType: "image/jpeg", maxBytes: Number(data.expectedBytes), mediaType: "panorama-derivative", assetId: data.assetId, tourId, nodeId, revisionId, derivativeSha256: data.derivativeSha256, exp: Math.floor(tokenExpiry.getTime() / 1000) }, uid, reservationId);
  await db.runTransaction(async (tx) => {
    const quota = documentData(await tx.get("system_config/storage_quota"));
    if (!quota || quota.storageProvider !== "cloudflare_r2" || quota.limitBytes !== LIMIT || !Number.isSafeInteger(quota.usedBytes) || !Number.isSafeInteger(quota.reservedBytes) || Number(quota.usedBytes) < 0 || Number(quota.reservedBytes) < 0 || Number(quota.usedBytes) + Number(quota.reservedBytes) > LIMIT) throw new ApiError(412, "R2 storage accounting is not initialized or is inconsistent. Uploads are paused until an administrator reconciles storage.");
    if (quota.uploadEnabled !== true || quota.maintenanceLock === true) throw new ApiError(429, "R2 uploads are temporarily paused while storage is checked.");
    const used = Number(quota.usedBytes), reserved = Number(quota.reservedBytes), requested = Number(data.expectedBytes);
    if (used + reserved + requested > LIMIT) throw new ApiError(429, "STORAGE_LIMIT_REACHED");
    const nextReserved = reserved + requested, previousState = quotaState(used, reserved), nextState = quotaState(used, nextReserved);
    tx.create(`uploadReservations/${reservationId}`, { reservationId, uid, assetId: data.assetId, mediaType: "panorama", objectKey, reservedBytes: requested, purpose: "processed", tourId, nodeId, revisionId, derivativeSha256: data.derivativeSha256, processingVersion: data.processingVersion, originalPath, status: "reserved", createdAt: now, expiresAt });
    if ((previousState === "normal" && nextState !== "normal") || (previousState === "warning" && ["critical", "full"].includes(nextState))) {
      tx.create(`storageAudit/${crypto.randomUUID()}`, { action: nextState === "warning" ? "quota.warning" : nextState === "full" ? "quota.full" : "quota.critical", state: nextState, usagePercent: ((used + nextReserved) / LIMIT) * 100, reservedBytes: requested, createdAt: now });
    }
    tx.patch("system_config/storage_quota", { reservedBytes: nextReserved, remainingBytes: LIMIT - used - nextReserved, usagePercent: ((used + nextReserved) / LIMIT) * 100, updatedAt: now });
  });
  return Response.json({ reservationId, objectKey, uploadUrl, uploadToken, expiresAt: tokenExpiry.toISOString() }, { headers: { "Cache-Control": "no-store" } });
}

function quotaState(used: number, reserved: number): "normal" | "warning" | "critical" | "full" {
  const ratio = (used + reserved) / LIMIT;
  return ratio >= 1 ? "full" : ratio >= 0.9 ? "critical" : ratio >= 0.8 ? "warning" : "normal";
}
