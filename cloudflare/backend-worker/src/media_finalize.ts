import { documentData, FirestoreRest } from "./firestore.js";
import type { Env, Principal } from "./index.js";
import { ApiError } from "./errors.js";
import { gatewayDelete, gatewayHead, gatewayPut, gatewayRead, gatewayBase } from "./r2_gateway_client.js";
import { IMAGE_FORMATS, MAX_IMAGE_BYTES, stripImageMetadata } from "./image_sanitizer.js";
import { deleteStoredObject } from "./storage_orphans.js";

const LIMIT = 9_000_000_000;
const quotaPath = "system_config/storage_quota";
const validBytes = (value: unknown): value is number => typeof value === "number" && Number.isSafeInteger(value) && value >= 0;

function ledgerPath(key: string): Promise<string> {
  return crypto.subtle.digest("SHA-256", new TextEncoder().encode(key)).then((raw) => `storageObjects/${Array.from(new Uint8Array(raw), (byte) => byte.toString(16).padStart(2, "0")).join("")}`);
}
function quotaValues(used: number, reserved: number, now: Date) {
  return { limitBytes: LIMIT, usedBytes: used, reservedBytes: reserved, remainingBytes: LIMIT - used - reserved, usagePercent: ((used + reserved) / LIMIT) * 100, updatedAt: now };
}

export async function completeReservation(db: FirestoreRest, reservationId: string, actualBytes: number, mediaUpdate?: Record<string, unknown>): Promise<void> {
  if (!validBytes(actualBytes) || actualBytes <= 0) throw new ApiError(502, "R2 returned an invalid object size.");
  const reservationPath = `uploadReservations/${reservationId}`;
  await db.runTransaction(async (tx) => {
    const reservationDoc = await tx.get(reservationPath), reservation = documentData(reservationDoc);
    if (!reservationDoc || !reservation) throw new ApiError(404, "The upload reservation was not found.");
    const key = String(reservation.objectKey), ledger = await tx.get(await ledgerPath(key));
    const mediaPath = `mediaAssets/${reservation.uid}_${reservation.assetId}`;
    const [quotaDoc, mediaDoc] = await Promise.all([tx.get(quotaPath), tx.get(mediaPath)]);
    const quota = documentData(quotaDoc), ledgerData = documentData(ledger);
    if (!quota || !validBytes(quota.usedBytes) || !validBytes(quota.reservedBytes)) throw new ApiError(412, "R2 storage accounting is not available.");
    if (reservation.status === "completed") {
      if (Number(reservation.actualBytes) !== actualBytes || ledgerData?.accountingState !== "counted") throw new ApiError(502, "The completed upload does not match its storage record.");
      return;
    }
    if (reservation.status !== "reserved" || actualBytes > Number(reservation.reservedBytes)) throw new ApiError(429, "The actual upload size exceeds its reservation.");
    if (ledgerData) throw new ApiError(409, "This object is already included in storage accounting.");
    const used = quota.usedBytes + actualBytes, reserved = quota.reservedBytes - Number(reservation.reservedBytes);
    if (reserved < 0 || used + reserved > LIMIT) throw new ApiError(502, "R2 storage accounting would exceed its configured limit.");
    const now = new Date();
    tx.create(await ledgerPath(key), { objectKey: key, sizeBytes: actualBytes, uid: reservation.uid, assetId: reservation.assetId, mediaType: reservation.mediaType, reservationId, accountingState: "counted", countedInQuota: true, createdAt: now, updatedAt: now });
    tx.patch(reservationPath, { status: "completed", actualBytes, completedAt: now, updatedAt: now });
    if (mediaUpdate) {
      if (!mediaDoc) throw new ApiError(404, "Media metadata was not found.");
      tx.patch(mediaPath, { ...mediaUpdate, updatedAt: now });
    }
    tx.patch(quotaPath, quotaValues(used, reserved, now));
    tx.create(`storageAudit/${crypto.randomUUID()}`, { action: "object.uploaded", objectKey: key, sizeBytes: actualBytes, uid: reservation.uid, assetId: reservation.assetId, mediaType: reservation.mediaType, reservationId, createdAt: now });
  });
}

async function reserveProcessed(db: FirestoreRest, input: { reservationId: string; uid: string; assetId: string; mediaType: string; objectKey: string; bytes: number }): Promise<Record<string, unknown>> {
  const path = `uploadReservations/${input.reservationId}`, now = new Date(), expiresAt = new Date(now.getTime() + 10 * 60_000);
  return db.runTransaction(async (tx) => {
    const [quotaDoc, oldDoc] = await Promise.all([tx.get(quotaPath), tx.get(path)]);
    const quota = documentData(quotaDoc), old = documentData(oldDoc);
    if (old) {
      if (old.objectKey !== input.objectKey || Number(old.reservedBytes) !== input.bytes) throw new ApiError(502, "The processed-image reservation does not match its output.");
      return old;
    }
    if (!quota || quota.storageProvider !== "cloudflare_r2" || quota.limitBytes !== LIMIT || !validBytes(quota.usedBytes) || !validBytes(quota.reservedBytes) || quota.usedBytes + quota.reservedBytes > LIMIT) throw new ApiError(412, "R2 storage accounting is unavailable.");
    if (quota.uploadEnabled !== true || quota.maintenanceLock === true) throw new ApiError(429, "R2 uploads are temporarily paused while storage is checked.");
    if (quota.usedBytes + quota.reservedBytes + input.bytes > LIMIT) throw new ApiError(429, "STORAGE_LIMIT_REACHED");
    const created = { reservationId: input.reservationId, uid: input.uid, assetId: input.assetId, mediaType: input.mediaType, objectKey: input.objectKey, reservedBytes: input.bytes, purpose: "processed", status: "reserved", createdAt: now, expiresAt };
    tx.create(path, created);
    const previousRatio = (quota.usedBytes + quota.reservedBytes) / LIMIT, nextRatio = (quota.usedBytes + quota.reservedBytes + input.bytes) / LIMIT;
    const previousState = previousRatio >= 1 ? "full" : previousRatio >= 0.9 ? "critical" : previousRatio >= 0.8 ? "warning" : "normal";
    const nextState = nextRatio >= 1 ? "full" : nextRatio >= 0.9 ? "critical" : nextRatio >= 0.8 ? "warning" : "normal";
    if ((previousState === "normal" && nextState !== "normal") || (previousState === "warning" && ["critical", "full"].includes(nextState))) {
      tx.create(`storageAudit/${crypto.randomUUID()}`, { action: nextState === "warning" ? "quota.warning" : nextState === "full" ? "quota.full" : "quota.critical", state: nextState, usagePercent: nextRatio * 100, reservedBytes: input.bytes, createdAt: now });
    }
    tx.patch(quotaPath, { reservedBytes: quota.reservedBytes + input.bytes, remainingBytes: LIMIT - quota.usedBytes - quota.reservedBytes - input.bytes, usagePercent: nextRatio * 100, updatedAt: now });
    return created;
  });
}

async function releaseReservation(db: FirestoreRest, reservationPath: string, reason: string): Promise<void> {
  await db.runTransaction(async (tx) => {
    const [reservationDoc, quotaDoc] = await Promise.all([tx.get(reservationPath), tx.get(quotaPath)]);
    const reservation = documentData(reservationDoc), quota = documentData(quotaDoc);
    if (!reservation || reservation.status === "released") return;
    if (reservation.status !== "reserved" || !quota || Number(quota.reservedBytes) < Number(reservation.reservedBytes)) throw new ApiError(502, "A completed reservation must be released by deleting its stored object.");
    const reserved = Number(quota.reservedBytes) - Number(reservation.reservedBytes), used = Number(quota.usedBytes), now = new Date();
    tx.patch(reservationPath, { status: "released", releaseReason: reason, releasedAt: now, updatedAt: now });
    tx.patch(quotaPath, quotaValues(used, reserved, now));
  });
}

async function discard(db: FirestoreRest, env: Env, reservationId: string, key: string, uid: string, assetId: string, reason: string): Promise<void> {
  const reservation = documentData(await db.get(`uploadReservations/${reservationId}`));
  if (reservation?.status === "completed") await deleteStoredObject(db, env, key, uid, reason);
  else {
    await gatewayDelete(env, key);
    if (await gatewayHead(env, key)) throw new ApiError(503, "The invalid upload could not be removed from storage.");
    await releaseReservation(db, `uploadReservations/${reservationId}`, reason);
  }
  await db.runTransaction(async (tx) => {
    const path = `mediaAssets/${uid}_${assetId}`;
    const media = await tx.get(path), now = new Date();
    if (media) tx.patch(path, { status: "failed", accountingState: "deleted", reason, updatedAt: now });
  });
}

async function finishProcessed(db: FirestoreRest, env: Env, input: { uid: string; assetId: string; mediaType: "product" | "store"; sourceKey: string; outputKey: string; bytes: number; contentType: string; extension: string; reservationId: string }): Promise<Record<string, unknown>> {
  const { uid, assetId, mediaType, sourceKey, outputKey, bytes, contentType, extension, reservationId } = input;
  const output = await gatewayHead(env, outputKey);
  if (!output || output.size !== bytes || output.contentType !== contentType) throw new ApiError(502, "The processed R2 object could not be verified.");
  const mediaPath = `mediaAssets/${uid}_${assetId}`, now = new Date();
  await db.runTransaction(async (tx) => {
    if (!await tx.get(mediaPath)) throw new ApiError(404, "Media metadata was not found.");
    tx.patch(mediaPath, { status: "processing", pendingOutputPath: outputKey, pendingOutputSize: bytes, pendingContentType: contentType, processingReservationId: `${reservationId}_processed`, updatedAt: now });
  });
  if (await gatewayHead(env, sourceKey)) await deleteStoredObject(db, env, sourceKey, uid, "media-processed");
  const product = mediaType === "product", downloadUrl = product ? `${gatewayBase(env)}/v1/media/public/${encodeURIComponent(outputKey)}` : undefined;
  await db.runTransaction(async (tx) => {
    const media = documentData(await tx.get(mediaPath));
    if (!media) throw new ApiError(404, "Media metadata was not found.");
    tx.patch(mediaPath, {
      status: "ready", ...(product ? { publicPath: outputKey, downloadUrl } : { privatePath: outputKey }),
      objectKey: outputKey, size: bytes, contentType, metadataStripped: true, accountingState: "counted", extension,
      updatedAt: new Date(),
    }, ["pendingOutputPath", "pendingOutputSize", "pendingContentType", "processingReservationId"]);
  });
  return { assetId, status: "ready", ...(downloadUrl ? { downloadUrl } : {}) };
}

export async function finalizeMediaUpload(request: Request, env: Env, principal: Principal): Promise<Response> {
  if (request.method !== "POST") return Response.json({ error: "Method not allowed." }, { status: 405, headers: { Allow: "POST" } });
  let data: Record<string, unknown>;
  try { const value: unknown = await request.json(); if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error(); data = value as Record<string, unknown>; }
  catch { throw new ApiError(400, "A valid JSON object is required."); }
  if (typeof data.reservationId !== "string" || !/^[A-Za-z0-9_-]{16,128}$/.test(data.reservationId)) throw new ApiError(400, "A valid upload reservation ID is required.");
  const db = new FirestoreRest(env), uid = principal.uid, reservationPath = `uploadReservations/${data.reservationId}`;
  if (!documentData(await db.get(`users/${uid}`))) throw new ApiError(403, "This account is no longer active.");
  const reservation = documentData(await db.get(reservationPath));
  if (!reservation) throw new ApiError(404, "The upload reservation was not found.");
  if (reservation.uid !== uid || reservation.purpose !== "upload") throw new ApiError(403, "This upload reservation does not belong to your account.");
  const mediaPath = `mediaAssets/${uid}_${reservation.assetId}`, media = documentData(await db.get(mediaPath));
  if (!media || media.reservationId !== reservation.reservationId) throw new ApiError(412, "Upload metadata is missing or inconsistent.");
  if (["released", "failed"].includes(String(reservation.status))) throw new ApiError(412, "This upload reservation has expired or failed.");
  if (["ready", "awaiting-privacy-processing"].includes(String(media.status))) return Response.json({ assetId: reservation.assetId, status: media.status, ...(typeof media.downloadUrl === "string" ? { downloadUrl: media.downloadUrl } : {}), ...(typeof media.originalPath === "string" ? { originalPath: media.originalPath } : {}) });
  if (media.status === "processing" && typeof media.pendingOutputPath === "string") {
    const pending = await gatewayHead(env, media.pendingOutputPath);
    if (pending && pending.size === Number(media.pendingOutputSize) && pending.contentType === media.pendingContentType) {
      return Response.json(await finishProcessed(db, env, { uid, assetId: String(reservation.assetId), mediaType: reservation.mediaType as "product" | "store", sourceKey: String(reservation.objectKey), outputKey: media.pendingOutputPath, bytes: pending.size, contentType: String(media.pendingContentType), extension: String(media.pendingOutputPath).split(".").at(-1) ?? "jpg", reservationId: data.reservationId }));
    }
  }
  const key = String(reservation.objectKey), actual = await gatewayHead(env, key);
  if (!actual) {
    if (reservation.status === "reserved") await releaseReservation(db, reservationPath, "upload-object-missing");
    else if (reservation.status === "completed") await deleteStoredObject(db, env, key, uid, "upload-object-missing");
    await db.runTransaction(async (tx) => { const current = await tx.get(mediaPath); if (current) tx.patch(mediaPath, { status: "failed", reason: "upload-object-missing", accountingState: "deleted", updatedAt: new Date() }); });
    throw new ApiError(404, "The R2 upload was not found. Upload the image again.");
  }
  if (actual.size > Number(reservation.reservedBytes) || actual.size <= 0 || actual.reservationId !== data.reservationId || actual.uid !== uid || actual.mediaType !== reservation.mediaType) {
    await discard(db, env, data.reservationId, key, uid, String(reservation.assetId), "upload-verification-failed");
    throw new ApiError(412, "The stored object did not match its upload reservation.");
  }
  if (reservation.mediaType === "panorama") {
    const format = IMAGE_FORMATS.find((candidate) => candidate.mime === actual.contentType);
    if (!format) {
      await discard(db, env, data.reservationId, key, uid, String(reservation.assetId), "invalid-image-content");
      throw new ApiError(400, "The uploaded file is not a valid JPEG, PNG, or WebP image.");
    }
    await completeReservation(db, data.reservationId, actual.size, { status: "awaiting-privacy-processing", originalPath: key, objectKey: key, tourId: Number(reservation.tourId), contentType: format.mime, size: actual.size, accountingState: "counted" });
    return Response.json({ assetId: reservation.assetId, status: "awaiting-privacy-processing", originalPath: key });
  }
  const bytes = await gatewayRead(env, key), format = IMAGE_FORMATS.find((candidate) => candidate.mime === actual.contentType);
  if (bytes.byteLength !== actual.size || !format || !format.signature(bytes)) {
    await discard(db, env, data.reservationId, key, uid, String(reservation.assetId), "invalid-image-content");
    throw new ApiError(400, "The uploaded file is not a valid JPEG, PNG, or WebP image.");
  }
  if (bytes.byteLength > MAX_IMAGE_BYTES) {
    await discard(db, env, data.reservationId, key, uid, String(reservation.assetId), "image-exceeds-maximum-size");
    throw new ApiError(429, "The image exceeds the 8 MiB limit.");
  }
  const sanitized = stripImageMetadata(bytes, format.mime);
  if (!sanitized || sanitized.byteLength === 0 || sanitized.byteLength > MAX_IMAGE_BYTES) {
    await discard(db, env, data.reservationId, key, uid, String(reservation.assetId), "invalid-image-structure");
    throw new ApiError(400, "The uploaded image could not be safely processed.");
  }
  await completeReservation(db, data.reservationId, bytes.byteLength, { status: "processing", quarantinePath: key, objectKey: key, size: bytes.byteLength, contentType: format.mime, accountingState: "counted" });
  const mediaType = reservation.mediaType as "product" | "store";
  const outputKey = mediaType === "product" ? `products/public/${uid}/${reservation.assetId}.${format.extension}` : `stores/processed/${uid}/${reservation.assetId}.${format.extension}`;
  const processedId = `${data.reservationId}_processed`;
  const processedReservation = await reserveProcessed(db, { reservationId: processedId, uid, assetId: String(reservation.assetId), mediaType, objectKey: outputKey, bytes: sanitized.byteLength });
  let output = await gatewayHead(env, outputKey);
  if (!output) {
    if (processedReservation.status === "completed") throw new ApiError(502, "A processed image is missing from R2 accounting.");
    await gatewayPut(env, outputKey, sanitized, format.mime, { reservationId: processedId, uid, mediaType });
    output = await gatewayHead(env, outputKey);
  }
  if (!output || output.size !== sanitized.byteLength || output.contentType !== format.mime) throw new ApiError(502, "The processed image did not match its verified output size.");
  await completeReservation(db, processedId, output.size);
  return Response.json(await finishProcessed(db, env, { uid, assetId: String(reservation.assetId), mediaType, sourceKey: key, outputKey, bytes: output.size, contentType: format.mime, extension: format.extension, reservationId: data.reservationId }));
}
