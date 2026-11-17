import { documentData, FirestoreRest } from "./firestore.js";
import type { Env, Principal } from "./index.js";
import { ApiError } from "./errors.js";
import { completeReservation } from "./media_finalize.js";
import { deleteStoredObject } from "./storage_orphans.js";
import { gatewayHead, gatewayPublicMediaUrl, gatewayPublishStoreImage, gatewayPut, gatewayRead } from "./r2_gateway_client.js";
import { geohash } from "./geohash.js";

const STORAGE_LIMIT = 9_000_000_000;

async function body(request: Request): Promise<Record<string, unknown>> {
  try {
    const value: unknown = await request.json();
    if (value && typeof value === "object" && !Array.isArray(value)) return value as Record<string, unknown>;
  } catch { /* invalid JSON */ }
  throw new ApiError(400, "A valid JSON object is required.");
}

function pathOf(name: string): string {
  const marker = "/documents/";
  return name.slice(name.indexOf(marker) + marker.length);
}

async function reservePublishedBytes(db: FirestoreRest, reservationId: string, uid: string, assetId: string, key: string, bytes: number): Promise<void> {
  const quotaPath = "system_config/storage_quota", reservationPath = `uploadReservations/${reservationId}`;
  await db.runTransaction(async (tx) => {
    const [quotaDoc, reservationDoc] = await Promise.all([tx.get(quotaPath), tx.get(reservationPath)]);
    const quota = documentData(quotaDoc), existing = documentData(reservationDoc);
    if (existing) {
      if (existing.objectKey !== key || Number(existing.reservedBytes) !== bytes || existing.uid !== uid || existing.assetId !== assetId || existing.purpose !== "published") {
        throw new ApiError(502, "The store publication reservation does not match the image.");
      }
      return;
    }
    if (!quota || quota.storageProvider !== "cloudflare_r2" || quota.limitBytes !== STORAGE_LIMIT ||
        !Number.isSafeInteger(quota.usedBytes) || !Number.isSafeInteger(quota.reservedBytes) ||
        Number(quota.usedBytes) < 0 || Number(quota.reservedBytes) < 0 || Number(quota.usedBytes) + Number(quota.reservedBytes) > STORAGE_LIMIT) {
      throw new ApiError(412, "R2 storage accounting is not initialized or is inconsistent.");
    }
    if (quota.uploadEnabled !== true || quota.maintenanceLock === true) throw new ApiError(429, "R2 uploads are temporarily paused while storage is checked.");
    if (Number(quota.usedBytes) + Number(quota.reservedBytes) + bytes > STORAGE_LIMIT) throw new ApiError(429, "STORAGE_LIMIT_REACHED");
    const now = new Date(), reservedBytes = Number(quota.reservedBytes) + bytes;
    tx.create(reservationPath, { reservationId, uid, assetId, mediaType: "store", objectKey: key, reservedBytes: bytes, purpose: "published", status: "reserved", createdAt: now, expiresAt: new Date(now.getTime() + 10 * 60_000) });
    tx.patch(quotaPath, { reservedBytes, remainingBytes: STORAGE_LIMIT - Number(quota.usedBytes) - reservedBytes, usagePercent: ((Number(quota.usedBytes) + reservedBytes) / STORAGE_LIMIT) * 100, updatedAt: now });
  });
}

export async function reviewStoreApplication(request: Request, env: Env, principal: Principal, forcedStatus?: string): Promise<Response> {
  if (request.method !== "POST") return Response.json({ error: "Method not allowed." }, { status: 405, headers: { Allow: "POST" } });
  const data = await body(request), storeId = data.storeId, status = forcedStatus ?? data.status ?? "approved";
  if (typeof storeId !== "number" || !Number.isSafeInteger(storeId) || storeId <= 0) throw new ApiError(400, "A valid store ID is required.");
  if (typeof status !== "string" || !["approved", "rejected", "suspended"].includes(status)) throw new ApiError(400, "Store status is not supported.");
  const db = new FirestoreRest(env), admin = documentData(await db.get(`users/${principal.uid}`));
  if (admin?.role !== "admin") throw new ApiError(403, "Administrator access is required.");
  const storeDoc = (await db.query("stores", [{ field: "numericId", op: "EQUAL", value: storeId }], 1))[0];
  const initialStore = documentData(storeDoc ?? null);
  if (!storeDoc || !initialStore) throw new ApiError(404, "Store application was not found.");
  const storePath = pathOf(storeDoc.name), linkedDocs = await db.query("mediaAssets", [{ field: "linkedStoreId", op: "EQUAL", value: storeId }], 1);
  const mediaDoc = linkedDocs[0], media = documentData(mediaDoc ?? null);
  let publicPath: string | undefined, publicUrl: string | undefined, sourcePrivatePath: string | undefined, publicationReservationId: string | undefined;
  if (status === "approved" && mediaDoc && media) {
    if (media.uid !== initialStore.ownerUid || media.mediaType !== "store" || !["ready", "approval-pending"].includes(String(media.status)) ||
        (typeof media.privatePath !== "string" && typeof media.publicPath !== "string")) throw new ApiError(412, "The store photo is not ready for publication.");
    sourcePrivatePath = typeof media.privatePath === "string" ? media.privatePath : undefined;
    const extension = String(media.extension ?? sourcePrivatePath?.split(".").at(-1) ?? "jpg");
    publicPath = typeof media.publicPath === "string" ? media.publicPath : `stores/public/${storeId}/${String(media.assetId)}.${extension}`;
    publicUrl = gatewayPublicMediaUrl(env, publicPath);
    if (typeof media.publicPath !== "string") {
      if (!sourcePrivatePath) throw new ApiError(412, "The private store image is unavailable.");
      const source = await gatewayHead(env, sourcePrivatePath);
      if (!source || source.size !== Number(media.size) || source.contentType !== media.contentType) throw new ApiError(412, "The private store image could not be verified in R2.");
      const bytes = await gatewayRead(env, sourcePrivatePath);
      if (bytes.byteLength !== source.size) throw new ApiError(502, "The store image size changed during approval.");
      publicationReservationId = `publish_${storeId}_${String(media.assetId)}`;
      await reservePublishedBytes(db, publicationReservationId, String(media.uid), String(media.assetId), publicPath, bytes.byteLength);
      const reservation = documentData(await db.get(`uploadReservations/${publicationReservationId}`));
      const existingPublic = await gatewayHead(env, publicPath);
      if (!existingPublic) {
        if (reservation?.status === "completed") throw new ApiError(502, "The prepared public store image is missing from R2.");
        await gatewayPut(env, publicPath, bytes, source.contentType, { reservationId: publicationReservationId, uid: String(media.uid), mediaType: "store" });
      }
      const verified = await gatewayHead(env, publicPath);
      if (!verified || verified.size !== bytes.byteLength || verified.contentType !== source.contentType) throw new ApiError(502, "The public store image could not be verified.");
      await completeReservation(db, publicationReservationId, verified.size);
      await db.runTransaction(async (tx) => {
        const current = documentData(await tx.get(pathOf(mediaDoc.name)));
        if (!current || current.linkedStoreId !== storeId || !["ready", "approval-pending"].includes(String(current.status))) throw new ApiError(412, "The store photo changed during approval.");
        tx.patch(pathOf(mediaDoc.name), { status: "approval-pending", pendingPublicPath: publicPath, pendingPublicReservationId: publicationReservationId, updatedAt: new Date() });
      });
    }
  }

  const rejectedKeys = status === "rejected" && media
    ? [media.objectKey, media.pendingPublicPath].filter((key): key is string => typeof key === "string")
    : [];
  let resultStatus = String(status);
  await db.runTransaction(async (tx) => {
    const store = documentData(await tx.get(storePath));
    if (!store) throw new ApiError(404, "Store application was not found.");
    if (store.status === status && !publicUrl) { resultStatus = String(status); return; }
    if (store.status === "rejected" || store.status === "suspended") {
      if (status !== "approved" || store.status === "rejected") throw new ApiError(412, "This store cannot transition to the requested status.");
    } else if (store.status !== "pending" && store.status !== "approved") throw new ApiError(412, "This store cannot transition to the requested status.");
    const ownerPath = `users/${String(store.ownerUid)}`, owner = documentData(await tx.get(ownerPath));
    if (!owner) throw new ApiError(412, "Store owner profile is missing.");
    const owned = Array.isArray(owner.ownedStoreIds) ? owner.ownedStoreIds.map(Number) : [];
    if (mediaDoc && publicPath) {
      const currentMedia = documentData(await tx.get(pathOf(mediaDoc.name)));
      if (currentMedia?.linkedStoreId !== storeId || !["ready", "approval-pending"].includes(String(currentMedia.status))) throw new ApiError(412, "The store photo changed during review.");
    }
    tx.patch(storePath, { status, geohash: geohash(Number(store.lat), Number(store.lng)), ...(publicUrl ? { image: publicUrl } : {}) });
    if (mediaDoc && publicPath && status === "approved") {
      tx.patch(pathOf(mediaDoc.name), { status: "ready", publicPath, downloadUrl: publicUrl, objectKey: publicPath, publishedAt: new Date().toISOString(), updatedAt: new Date() }, ["pendingPublicPath", "pendingPublicReservationId"]);
    } else if (mediaDoc && status === "rejected") {
      tx.patch(pathOf(mediaDoc.name), { status: "cleanup-pending", cleanupRequestedAt: new Date(), cleanupReason: "store-application-rejected", updatedAt: new Date() }, ["linkedStoreId"]);
    }
    if (status === "approved") tx.patch(ownerPath, { role: "owner", ownedStoreIds: [...new Set([...owned, storeId])] });
    tx.create(`auditLogs/${crypto.randomUUID()}`, { action: `store.status.${status}`, storeId, actorUid: principal.uid, ownerUid: store.ownerUid, created_at: new Date().toISOString() });
  });

  if (status === "approved" && publicPath) {
    await gatewayPublishStoreImage(env, publicPath);
    if (sourcePrivatePath && mediaDoc) {
      await deleteStoredObject(db, env, sourcePrivatePath, principal.uid, "store-image-published");
      await db.runTransaction(async (tx) => {
        if (await tx.get(pathOf(mediaDoc.name))) tx.patch(pathOf(mediaDoc.name), { sourceDeletedAt: new Date(), updatedAt: new Date() }, ["privatePath"]);
      });
    }
  }
  if (status === "rejected" && mediaDoc && rejectedKeys.length) {
    for (const key of new Set(rejectedKeys)) await deleteStoredObject(db, env, key, principal.uid, "store-application-rejected");
    await db.runTransaction(async (tx) => {
      if (await tx.get(pathOf(mediaDoc.name))) tx.patch(pathOf(mediaDoc.name), { status: "deleted", accountingState: "deleted", deletedAt: new Date(), updatedAt: new Date() });
    });
  }
  return Response.json({ id: storeId, status: resultStatus });
}
