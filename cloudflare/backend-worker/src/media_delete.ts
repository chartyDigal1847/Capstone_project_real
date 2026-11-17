import { documentData, FirestoreRest } from "./firestore.js";
import type { Env, Principal } from "./index.js";
import { ApiError } from "./errors.js";
import { deleteStoredObject } from "./storage_orphans.js";

async function body(request: Request): Promise<Record<string, unknown>> {
  try { const value: unknown = await request.json(); if (value && typeof value === "object" && !Array.isArray(value)) return value as Record<string, unknown>; }
  catch { /* invalid JSON */ }
  throw new ApiError(400, "A valid JSON object is required.");
}

async function rateLimit(db: FirestoreRest, uid: string): Promise<void> {
  await db.runTransaction(async (tx) => {
    const path = `systemRateLimits/${uid}_mediaDelete`, current = documentData(await tx.get(path));
    const now = new Date(), start = current?.windowStartedAt instanceof Date ? current.windowStartedAt : null;
    const elapsed = start ? now.getTime() - start.getTime() : null, active = elapsed !== null && elapsed >= 0 && elapsed < 3_600_000;
    const count = active ? Number(current?.count ?? 0) : 0;
    if (count >= 30) throw new ApiError(429, "You have reached the media deletion limit. Try again later.");
    tx.set(path, { uid, operation: "mediaDelete", windowStartedAt: active ? start! : now, count: count + 1, updatedAt: now });
  });
}

export async function claimMediaDeletion(db: FirestoreRest, mediaPath: string, actorUid: string): Promise<Record<string, unknown>> {
  return db.runTransaction(async (tx) => {
    const media = documentData(await tx.get(mediaPath));
    if (!media) throw new ApiError(404, "Media was not found.");
    if (media.uid !== actorUid) {
      const actor = documentData(await tx.get(`users/${actorUid}`));
      if (actor?.role !== "admin") throw new ApiError(403, "You cannot delete this media.");
    }
    if (media.linkedProductId != null || media.linkedStoreId != null || media.linkedTourId != null) throw new ApiError(412, "Remove this media from its product, store, or tour before deleting it.");
    const now = new Date();
    tx.patch(mediaPath, { status: "deleting", deletionStartedAt: now, updatedAt: now });
    return media;
  });
}

async function deleteRecord(db: FirestoreRest, env: Env, mediaPath: string, actorUid: string): Promise<Record<string, unknown>> {
  // Claim deletion and recheck links in one transaction so a concurrent product,
  // store, or tour link cannot be deleted based on a stale preflight read.
  const media = await claimMediaDeletion(db, mediaPath, actorUid);
  const derivativeDocs = await db.listSubcollection(mediaPath, "derivatives");
  const keys = [media.objectKey, media.quarantinePath, media.publicPath, media.privatePath, media.originalPath, media.pendingOutputPath, media.pendingPublicPath]
    .filter((key): key is string => typeof key === "string");
  for (const doc of derivativeDocs) {
    const key = documentData(doc)?.objectKey;
    if (typeof key === "string") keys.push(key);
  }
  for (const key of new Set(keys)) await deleteStoredObject(db, env, key, actorUid, "user-request");
  for (const derivative of derivativeDocs) {
    const path = derivative.name.split("/documents/")[1];
    await db.runTransaction(async (tx) => {
      if (await tx.get(path)) tx.patch(path, { status: "deleted", accountingState: "deleted", deletedAt: new Date() });
    });
  }
  await db.runTransaction(async (tx) => {
    if (await tx.get(mediaPath)) tx.patch(mediaPath, { status: "deleted", accountingState: "deleted", deletedAt: new Date(), updatedAt: new Date() });
  });
  return { ok: true, assetId: media.assetId };
}

export async function deleteMediaAsset(request: Request, env: Env, principal: Principal): Promise<Response> {
  if (request.method !== "POST") return Response.json({ error: "Method not allowed." }, { status: 405, headers: { Allow: "POST" } });
  const data = await body(request);
  if (typeof data.assetId !== "string" || !/^[A-Za-z0-9_-]{1,100}$/.test(data.assetId)) throw new ApiError(400, "A valid media ID is required.");
  const db = new FirestoreRest(env), mediaPath = `mediaAssets/${principal.uid}_${data.assetId}`;
  await rateLimit(db, principal.uid);
  let mediaDoc = await db.get(mediaPath), media = documentData(mediaDoc);
  if (!mediaDoc || !media) {
    const caller = documentData(await db.get(`users/${principal.uid}`));
    if (caller?.role !== "admin") throw new ApiError(404, "Media was not found.");
    const matching = await db.query("mediaAssets", [{ field: "assetId", op: "EQUAL", value: data.assetId }], 1);
    if (!matching.length) throw new ApiError(404, "Media was not found.");
    mediaDoc = matching[0];
    media = documentData(mediaDoc)!;
  }
  const path = mediaDoc.name.split("/documents/")[1];
  const result = await deleteRecord(db, env, path, principal.uid);
  return Response.json(result, { headers: { "Cache-Control": "no-store" } });
}
