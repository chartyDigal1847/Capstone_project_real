import { documentData, FirestoreRest } from "./firestore.js";
import type { Env, Principal } from "./index.js";
import { ApiError } from "./errors.js";
import { gatewayBase, signUploadCapability } from "./r2_gateway_client.js";

const LIMIT = 9_000_000_000;
const IMAGE_MAX = 8 * 1024 * 1024;
const PANORAMA_MAX = 50 * 1024 * 1024;
const MIME = new Set(["image/jpeg", "image/png", "image/webp"]);

async function body(request: Request): Promise<Record<string, unknown>> {
  const length = Number(request.headers.get("Content-Length") ?? 0);
  if (length > 16_384) throw new ApiError(413, "The request body is too large.");
  try { const value: unknown = await request.json(); if (value && typeof value === "object" && !Array.isArray(value)) return value as Record<string, unknown>; }
  catch { /* invalid JSON */ }
  throw new ApiError(400, "A valid JSON object is required.");
}

function quotaState(used: number, reserved: number): "normal" | "warning" | "critical" | "full" {
  const ratio = (used + reserved) / LIMIT;
  return ratio >= 1 ? "full" : ratio >= 0.9 ? "critical" : ratio >= 0.8 ? "warning" : "normal";
}

async function rateLimit(db: FirestoreRest, uid: string): Promise<void> {
  await db.runTransaction(async (tx) => {
    const path = `systemRateLimits/${uid}_mediaUpload`;
    const current = documentData(await tx.get(path));
    const now = new Date(), start = current?.windowStartedAt instanceof Date ? current.windowStartedAt : null;
    const elapsed = start ? now.getTime() - start.getTime() : null;
    const inWindow = elapsed !== null && elapsed >= 0 && elapsed < 3_600_000;
    const count = inWindow ? Number(current?.count ?? 0) : 0;
    if (count >= 10) throw new ApiError(429, "You have reached the upload request limit. Try again later.");
    tx.set(path, { uid, operation: "mediaUpload", windowStartedAt: inWindow ? start! : now, count: count + 1, updatedAt: now });
  });
}

async function authorize(db: FirestoreRest, uid: string, mediaType: string, tourId?: number): Promise<void> {
  const profile = documentData(await db.get(`users/${uid}`));
  if (!profile) throw new ApiError(412, "Your account profile is not ready yet.");
  const role = String(profile.role ?? "");
  if (mediaType === "product" && !["owner", "staff", "admin"].includes(role)) throw new ApiError(403, "Store product image upload permission is required.");
  if (mediaType === "store" && role === "admin") throw new ApiError(403, "Administrators cannot submit store applications.");
  if (mediaType !== "panorama") return;
  if (!tourId || !Number.isSafeInteger(tourId)) throw new ApiError(400, "A valid tour ID is required.");
  const tours = await db.query("tours", [{ field: "numericId", op: "EQUAL", value: tourId }], 1);
  if (!tours.length) throw new ApiError(404, "Tour was not found.");
  const tour = documentData(tours[0])!;
  const stores = await db.query("stores", [{ field: "numericId", op: "EQUAL", value: Number(tour.storeId) }], 1);
  if (!stores.length || documentData(stores[0])?.status !== "approved") throw new ApiError(412, "Only tours for approved stores can accept panoramas.");
  const store = documentData(stores[0])!;
  if (role !== "admin" && (store.ownerUid !== uid || tour.ownerUid !== uid || tour.status !== "draft")) throw new ApiError(403, "Only the tour owner or an administrator can upload its panoramas.");
}

export async function reserveMediaUpload(request: Request, env: Env, principal: Principal): Promise<Response> {
  if (request.method !== "POST") return Response.json({ error: "Method not allowed." }, { status: 405, headers: { Allow: "POST" } });
  const data = await body(request), uid = principal.uid;
  const mediaType = data.mediaType;
  if (typeof mediaType !== "string" || !["product", "store", "panorama"].includes(mediaType)) throw new ApiError(400, "The media type is not supported.");
  if (typeof data.assetId !== "string" || !/^[A-Za-z0-9_-]{1,100}$/.test(data.assetId)) throw new ApiError(400, "A valid media ID is required.");
  if (typeof data.contentType !== "string" || !MIME.has(data.contentType)) throw new ApiError(400, "Use a JPEG, PNG, or WebP image.");
  const maxBytes = mediaType === "panorama" ? PANORAMA_MAX : IMAGE_MAX;
  if (!Number.isSafeInteger(data.expectedBytes) || Number(data.expectedBytes) <= 0 || Number(data.expectedBytes) > maxBytes) throw new ApiError(400, `The file must be no larger than ${mediaType === "panorama" ? "50 MiB" : "8 MiB"}.`);
  const tourId = mediaType === "panorama" ? data.tourId : undefined;
  if (mediaType === "panorama" && (!Number.isSafeInteger(tourId) || Number(tourId) <= 0)) throw new ApiError(400, "A valid tour ID is required.");
  const db = new FirestoreRest(env);
  await authorize(db, uid, mediaType, tourId as number | undefined);
  await rateLimit(db, uid);
  const reservationId = crypto.randomUUID(), assetId = data.assetId;
  const objectKey = mediaType === "product" ? `products/quarantine/${uid}/${assetId}`
    : mediaType === "store" ? `stores/quarantine/${uid}/${assetId}`
      : `tours/originals/${uid}/${Number(tourId)}/${assetId}`;
  const now = new Date(), tokenExpires = new Date(now.getTime() + 5 * 60_000), expiresAt = new Date(tokenExpires.getTime() + 5 * 60_000);
  const uploadUrl = `${gatewayBase(env)}/v1/uploads/${encodeURIComponent(reservationId)}`;
  const token = await signUploadCapability(env, { scope: "upload", objectKey, contentType: data.contentType, maxBytes: Number(data.expectedBytes), mediaType, assetId, ...(tourId ? { tourId } : {}), exp: Math.floor(tokenExpires.getTime() / 1000) }, uid, reservationId);
  await db.runTransaction(async (tx) => {
    const reservationPath = `uploadReservations/${reservationId}`, mediaPath = `mediaAssets/${uid}_${assetId}`;
    const [quotaDoc, oldReservation, mediaDoc] = await Promise.all([tx.get("system_config/storage_quota"), tx.get(reservationPath), tx.get(mediaPath)]);
    const quota = documentData(quotaDoc), requested = Number(data.expectedBytes);
    if (documentData(oldReservation)) throw new ApiError(409, "This upload reservation already exists.");
    if (mediaType === "product" || mediaType === "store" || mediaType === "panorama") if (documentData(mediaDoc)) throw new ApiError(409, "This media ID has already been used.");
    if (!quota || quota.storageProvider !== "cloudflare_r2" || quota.limitBytes !== LIMIT || !Number.isSafeInteger(quota.usedBytes) || !Number.isSafeInteger(quota.reservedBytes) || Number(quota.usedBytes) < 0 || Number(quota.reservedBytes) < 0 || Number(quota.usedBytes) + Number(quota.reservedBytes) > LIMIT) throw new ApiError(412, "R2 storage accounting is not initialized or is inconsistent. Uploads are paused until an administrator reconciles storage.");
    if (quota.uploadEnabled !== true || quota.maintenanceLock === true) throw new ApiError(429, "R2 uploads are temporarily paused while storage is checked.");
    const used = Number(quota.usedBytes), reserved = Number(quota.reservedBytes);
    if (used + reserved + requested > LIMIT) throw new ApiError(429, "STORAGE_LIMIT_REACHED");
    const next = reserved + requested, previousState = quotaState(used, reserved), nextState = quotaState(used, next);
    tx.create(reservationPath, { reservationId, uid, assetId, mediaType, objectKey, reservedBytes: requested, purpose: "upload", ...(tourId ? { tourId } : {}), status: "reserved", createdAt: now, expiresAt });
    tx.create(mediaPath, { uid, assetId, mediaType, status: "uploading", reservationId, objectKey, ...(tourId ? { tourId } : {}), size: 0, accountingState: "reserved", createdAt: now, updatedAt: now });
    if ((previousState === "normal" && nextState !== "normal") || (previousState === "warning" && ["critical", "full"].includes(nextState))) {
      tx.create(`storageAudit/${crypto.randomUUID()}`, { action: nextState === "warning" ? "quota.warning" : nextState === "full" ? "quota.full" : "quota.critical", state: nextState, usagePercent: ((used + next) / LIMIT) * 100, reservedBytes: requested, createdAt: now });
    }
    tx.patch("system_config/storage_quota", { reservedBytes: next, remainingBytes: LIMIT - used - next, usagePercent: ((used + next) / LIMIT) * 100, updatedAt: now });
  });
  return Response.json({ reservationId, objectKey, uploadUrl, uploadToken: token, expiresAt: tokenExpires.toISOString() }, { headers: { "Cache-Control": "no-store" } });
}
