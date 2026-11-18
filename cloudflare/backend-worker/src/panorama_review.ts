import { documentData, FirestoreRest } from "./firestore.js";
import type { Env, Principal } from "./index.js";
import { ApiError } from "./errors.js";

function reviewInput(data: Record<string, unknown>) {
  if (!Number.isSafeInteger(data.tourId) || Number(data.tourId) <= 0 || !Number.isSafeInteger(data.nodeId) || Number(data.nodeId) <= 0) throw new ApiError(400, "Valid tour and viewpoint IDs are required.");
  if (typeof data.derivativeSha256 !== "string" || !/^[a-f0-9]{64}$/.test(data.derivativeSha256)) throw new ApiError(400, "A lowercase derivative SHA-256 digest is required.");
  const unblurredConsent = data.processingVersion === "localspot-panorama-original-v1";
  if (typeof data.processingVersion !== "string" || !/^(?:localspot-panorama-local-v[0-9]{1,8}|localspot-panorama-original-v1)$/.test(data.processingVersion)) throw new ApiError(400, "The panorama processing version is invalid.");
  if (unblurredConsent) {
    if (data.unblurredConsent !== true || !Array.isArray(data.inspectedDirections) || data.inspectedDirections.length !== 0 || data.acknowledgedMissRisk !== true || data.acknowledgedManualInspection !== false) throw new ApiError(412, "Explicit owner consent is required to publish the original panorama without face blur.");
  } else {
    if (data.unblurredConsent === true || !Array.isArray(data.inspectedDirections) || data.inspectedDirections.length !== 48 || data.inspectedDirections.some((value) => !Number.isSafeInteger(value) || Number(value) < 0 || Number(value) >= 48) || new Set(data.inspectedDirections).size !== 48) throw new ApiError(412, "All 48 owner-review directions must be inspected.");
    if (data.acknowledgedMissRisk !== true || data.acknowledgedManualInspection !== true) throw new ApiError(412, "Both owner-review acknowledgements are required.");
  }
  return { tourId: Number(data.tourId), nodeId: Number(data.nodeId), derivativeSha256: data.derivativeSha256, processingVersion: data.processingVersion, inspectedDirections: (data.inspectedDirections as number[]).slice().sort((a, b) => a - b), unblurredConsent };
}

async function body(request: Request): Promise<Record<string, unknown>> {
  try { const value: unknown = await request.json(); if (value && typeof value === "object" && !Array.isArray(value)) return value as Record<string, unknown>; }
  catch { /* invalid JSON */ }
  throw new ApiError(400, "A valid JSON object is required.");
}

export async function recordTourPanoramaReview(request: Request, env: Env, principal: Principal): Promise<Response> {
  if (request.method !== "POST") return Response.json({ error: "Method not allowed." }, { status: 405, headers: { Allow: "POST" } });
  const input = reviewInput(await body(request)), uid = principal.uid, db = new FirestoreRest(env);
  const tours = await db.query("tours", [{ field: "numericId", op: "EQUAL", value: input.tourId }], 1);
  if (!tours.length) throw new ApiError(404, "Tour was not found.");
  const tourPath = tours[0].name.split("/documents/")[1], initialTour = documentData(tours[0])!;
  const stores = await db.query("stores", [{ field: "numericId", op: "EQUAL", value: Number(initialTour.storeId) }], 1);
  if (!stores.length) throw new ApiError(404, "Store was not found.");
  const storePath = stores[0].name.split("/documents/")[1];
  return await db.runTransaction(async (tx) => {
    const [tourSnap, storeSnap] = await Promise.all([tx.get(tourPath), tx.get(storePath)]);
    const tour = documentData(tourSnap), store = documentData(storeSnap);
    if (!tour || !store) throw new ApiError(404, "Tour or store was not found.");
    if (tour.status !== "draft" || store.status !== "approved" || store.ownerUid !== uid || tour.ownerUid !== uid) throw new ApiError(403, "Only the authenticated owner can review a draft tour viewpoint.");
    if (Number(tour.storeId) !== Number(store.numericId)) throw new ApiError(412, "Tour ownership metadata is inconsistent.");
    if (!Array.isArray(tour.nodes)) throw new ApiError(502, "Tour viewpoint data is invalid.");
    const nodes = tour.nodes as Array<Record<string, unknown>>;
    const index = nodes.findIndex((node) => Number(node.id) === input.nodeId);
    if (index < 0) throw new ApiError(404, "Viewpoint was not found.");
    const node = nodes[index], prefix = `tours/originals/${uid}/${input.tourId}/`;
    if (typeof node.original_path !== "string" || !node.original_path.startsWith(prefix)) throw new ApiError(403, "The viewpoint original does not belong to this owner.");
    const derivative = node.verified_derivative as Record<string, unknown> | undefined;
    const revisionValid = typeof derivative?.revisionId === "string" && /^[a-f0-9]{32}$/.test(derivative.revisionId);
    const expectedKey = revisionValid ? `tours/derivatives/${uid}/${input.tourId}/${input.nodeId}/${derivative!.revisionId}_${input.derivativeSha256}.jpg` : "";
    if (!derivative || derivative.status !== "verified" || derivative.objectKey !== expectedKey || derivative.sha256 !== input.derivativeSha256 || derivative.contentType !== "image/jpeg" || !Number.isSafeInteger(derivative.size) || Number(derivative.size) <= 0 || derivative.processingVersion !== input.processingVersion || derivative.accountingState !== "counted" || typeof derivative.reservationId !== "string" || !(derivative.verifiedAt instanceof Date)) throw new ApiError(412, "The current panorama derivative has not been verified and quota-accounted by the backend.");
    const old = node.owner_review as Record<string, unknown> | undefined;
    const directionCount = input.unblurredConsent ? 0 : 48;
    const recordType = input.unblurredConsent ? "owner-consented-unblurred" : "owner-attestation-not-privacy-proof";
    if (node.owner_reviewed === true && old?.ownerUid === uid && old.derivativeSha256 === input.derivativeSha256 && old.processingVersion === input.processingVersion && JSON.stringify(old.inspectedDirections) === JSON.stringify(input.inspectedDirections) && old.acknowledgedMissRisk === true && old.acknowledgedManualInspection === !input.unblurredConsent && old.unblurredConsent === input.unblurredConsent && old.reviewedAt instanceof Date) {
      return Response.json({ ok: true, tourId: input.tourId, nodeId: input.nodeId, review: { ownerUid: uid, reviewedAt: old.reviewedAt.toISOString(), derivativeSha256: input.derivativeSha256, processingVersion: input.processingVersion, inspectedDirections: input.inspectedDirections, directionCount, acknowledgedMissRisk: true, acknowledgedManualInspection: !input.unblurredConsent, unblurredConsent: input.unblurredConsent, recordType } });
    }
    const reviewedAt = new Date(), review = { ownerUid: uid, reviewedAt, derivativeSha256: input.derivativeSha256, processingVersion: input.processingVersion, inspectedDirections: input.inspectedDirections, directionCount, acknowledgedMissRisk: true, acknowledgedManualInspection: !input.unblurredConsent, unblurredConsent: input.unblurredConsent, recordType };
    nodes[index] = { ...node, owner_review: review, owner_reviewed: true, privacy_status: "ready" };
    tx.patch(tourPath, { nodes, updatedAt: reviewedAt });
    return Response.json({ ok: true, tourId: input.tourId, nodeId: input.nodeId, review: { ...review, reviewedAt: reviewedAt.toISOString() } });
  });
}
