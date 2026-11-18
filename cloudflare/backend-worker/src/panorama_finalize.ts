import { documentData, FirestoreRest } from "./firestore.js";
import type { Env, Principal } from "./index.js";
import { ApiError } from "./errors.js";
import { completeReservation } from "./media_finalize.js";
import { gatewayDelete, gatewayHead } from "./r2_gateway_client.js";
import { deleteStoredObject } from "./storage_orphans.js";

const DERIVATIVE_KEY = /^tours\/derivatives\/([A-Za-z0-9_-]{1,128})\/([1-9][0-9]{0,15})\/([1-9][0-9]{0,15})\/([A-Za-z0-9_-]{16,64})_([a-f0-9]{64})\.jpg$/;

async function discardInvalid(db: FirestoreRest, env: Env, reservation: Record<string, unknown>, reservationId: string): Promise<void> {
  const key = String(reservation.objectKey), mediaUid = String(reservation.uid);
  if (reservation.status === "completed") await deleteStoredObject(db, env, key, mediaUid, "derivative-content-verification-failed");
  else {
    await gatewayDelete(env, key);
    if (await gatewayHead(env, key)) throw new ApiError(503, "An invalid derivative could not be removed safely.");
    await db.runTransaction(async (tx) => {
      const path = `uploadReservations/${reservationId}`;
      const [reservationDoc, quotaDoc] = await Promise.all([tx.get(path), tx.get("system_config/storage_quota")]);
      const current = documentData(reservationDoc), quota = documentData(quotaDoc);
      if (!current || current.status !== "reserved") return;
      if (!quota || Number(quota.reservedBytes) < Number(current.reservedBytes)) throw new ApiError(502, "The derivative reservation counter is inconsistent.");
      const reserved = Number(quota.reservedBytes) - Number(current.reservedBytes), used = Number(quota.usedBytes), now = new Date();
      tx.patch(path, { status: "released", releaseReason: "derivative-content-verification-failed", releasedAt: now, updatedAt: now });
      tx.patch("system_config/storage_quota", { limitBytes: 9_000_000_000, usedBytes: used, reservedBytes: reserved, remainingBytes: 9_000_000_000 - used - reserved, usagePercent: ((used + reserved) / 9_000_000_000) * 100, updatedAt: now });
    });
  }
}

export async function finalizePanoramaDerivativeUpload(request: Request, env: Env, principal: Principal): Promise<Response> {
  if (request.method !== "POST") return Response.json({ error: "Method not allowed." }, { status: 405, headers: { Allow: "POST" } });
  let data: Record<string, unknown>;
  try { const value: unknown = await request.json(); if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error(); data = value as Record<string, unknown>; }
  catch { throw new ApiError(400, "A valid JSON object is required."); }
  if (typeof data.reservationId !== "string" || !/^[A-Za-z0-9_-]{16,128}$/.test(data.reservationId)) throw new ApiError(400, "A valid derivative reservation ID is required.");
  const reservationId = data.reservationId, db = new FirestoreRest(env), reservationPath = `uploadReservations/${reservationId}`;
  const reservation = documentData(await db.get(reservationPath));
  if (!reservation) throw new ApiError(404, "The derivative reservation was not found.");
  if (reservation.uid !== principal.uid || reservation.mediaType !== "panorama" || reservation.purpose !== "processed") throw new ApiError(403, "This derivative reservation does not belong to your account.");
  const key = String(reservation.objectKey), match = DERIVATIVE_KEY.exec(key);
  if (!match || match[1] !== principal.uid || Number(match[2]) !== Number(reservation.tourId) || Number(match[3]) !== Number(reservation.nodeId) || match[4] !== reservation.revisionId || match[5] !== reservation.derivativeSha256) throw new ApiError(502, "The derivative reservation key is inconsistent.");
  const object = await gatewayHead(env, key);
  if (!object) {
    if (reservation.status === "reserved") await db.runTransaction(async (tx) => {
      const [reservationDoc, quotaDoc] = await Promise.all([tx.get(reservationPath), tx.get("system_config/storage_quota")]);
      const current = documentData(reservationDoc), quota = documentData(quotaDoc);
      if (!current || current.status !== "reserved") return;
      if (!quota || Number(quota.reservedBytes) < Number(current.reservedBytes)) throw new ApiError(502, "The derivative reservation counter is inconsistent.");
      const used = Number(quota.usedBytes), reserved = Number(quota.reservedBytes) - Number(current.reservedBytes), now = new Date();
      tx.patch(reservationPath, { status: "released", releaseReason: "derivative-object-missing", releasedAt: now, updatedAt: now });
      tx.patch("system_config/storage_quota", { limitBytes: 9_000_000_000, usedBytes: used, reservedBytes: reserved, remainingBytes: 9_000_000_000 - used - reserved, usagePercent: ((used + reserved) / 9_000_000_000) * 100, updatedAt: now });
    });
    throw new ApiError(404, "The uploaded derivative was not found.");
  }
  if (object.key !== key || object.reservationId !== reservationId || object.uid !== principal.uid || object.mediaType !== "panorama-derivative") throw new ApiError(412, "The stored object is not owned by this derivative reservation.");
  if (!Number.isSafeInteger(object.size) || object.size <= 0 || object.size > Number(reservation.reservedBytes) || object.contentType !== "image/jpeg" ||
      object.verifiedSha256 !== reservation.derivativeSha256) {
    await discardInvalid(db, env, reservation, reservationId);
    throw new ApiError(412, "The uploaded derivative failed its JPEG, size, ownership, or SHA-256 verification.");
  }
  await completeReservation(db, reservationId, object.size);
  const tourMatches = await db.query("tours", [{ field: "numericId", op: "EQUAL", value: Number(reservation.tourId) }], 1);
  if (!tourMatches.length) throw new ApiError(404, "Tour was not found after derivative accounting finalized.");
  const tourDoc = tourMatches[0], tourPath = tourDoc.name.split("/documents/")[1], tour = documentData(tourDoc)!;
  const storeMatches = await db.query("stores", [{ field: "numericId", op: "EQUAL", value: Number(tour.storeId) }], 1);
  if (!storeMatches.length) throw new ApiError(404, "Store was not found after derivative accounting finalized.");
  const storePath = storeMatches[0].name.split("/documents/")[1], mediaPath = `mediaAssets/${principal.uid}_${reservation.assetId}`;
  const revisionPath = `${mediaPath}/derivatives/${reservation.revisionId}`, verifiedAt = new Date();
  const actualHash = object.verifiedSha256;
  const unblurred = reservation.processingVersion === "localspot-panorama-original-v1";
  const verified = { status: "verified", objectKey: key, size: object.size, contentType: "image/jpeg", sha256: actualHash, revisionId: reservation.revisionId, processingVersion: reservation.processingVersion, reservationId, accountingState: "counted", verifiedAt };
  const ownerReview = unblurred ? {
    ownerUid: principal.uid,
    reviewedAt: verifiedAt,
    derivativeSha256: actualHash,
    processingVersion: reservation.processingVersion,
    inspectedDirections: [],
    directionCount: 0,
    acknowledgedMissRisk: true,
    acknowledgedManualInspection: false,
    unblurredConsent: true,
    recordType: "owner-consented-unblurred",
  } : null;
  await db.runTransaction(async (tx) => {
    const [currentTourDoc, storeDoc, mediaDoc, revisionDoc] = await Promise.all([tx.get(tourPath), tx.get(storePath), tx.get(mediaPath), tx.get(revisionPath)]);
    const currentTour = documentData(currentTourDoc), store = documentData(storeDoc), media = documentData(mediaDoc);
    if (!currentTour || !store || !media) throw new ApiError(404, "The owner tour or original media record was not found.");
    if (currentTour.status !== "draft" || currentTour.ownerUid !== principal.uid || store.ownerUid !== principal.uid || store.status !== "approved" || media.uid !== principal.uid || media.originalPath !== reservation.originalPath || media.linkedTourId !== Number(reservation.tourId)) throw new ApiError(403, "The derivative no longer belongs to this owner's draft tour.");
    if (!Array.isArray(currentTour.nodes)) throw new ApiError(502, "Tour viewpoint data is invalid.");
    const nodes = currentTour.nodes as Array<Record<string, unknown>>;
    const index = nodes.findIndex((row) => Number(row.id) === Number(reservation.nodeId));
    if (index < 0 || nodes[index].original_path !== reservation.originalPath) throw new ApiError(412, "The panorama viewpoint changed after derivative reservation.");
    const revisionData = { ...verified, uid: principal.uid, assetId: reservation.assetId, tourId: Number(reservation.tourId), nodeId: Number(reservation.nodeId), createdAt: verifiedAt };
    if (revisionDoc) tx.patch(revisionPath, revisionData); else tx.create(revisionPath, revisionData);
    const current = nodes[index].verified_derivative as Record<string, unknown> | undefined;
    const reservationCreated = reservation.createdAt instanceof Date ? reservation.createdAt.getTime() : 0;
    const currentVerified = current?.verifiedAt instanceof Date ? current.verifiedAt.getTime() : 0;
    if (current?.status === "verified" && current.revisionId !== reservation.revisionId && currentVerified > reservationCreated) return;
    const nextNode = { ...nodes[index] };
    delete nextNode.owner_review;
    nodes[index] = {
      ...nextNode,
      ...(ownerReview ? { owner_review: ownerReview } : {}),
      verified_derivative: verified,
      privacy_status: unblurred ? "ready" : "awaiting-owner-review",
      owner_reviewed: unblurred,
      image: "",
    };
    tx.patch(tourPath, { nodes, updatedAt: verifiedAt });
    tx.patch(mediaPath, { latestDerivativeRevisionId: reservation.revisionId, latestDerivativeObjectKey: key, latestDerivativeSha256: actualHash, updatedAt: verifiedAt });
  });
  return Response.json({ status: "verified", objectKey: key, size: object.size, contentType: "image/jpeg", sha256: actualHash, revisionId: reservation.revisionId, reservationId, accountingState: "counted" }, { headers: { "Cache-Control": "no-store" } });
}
