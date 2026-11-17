import { documentData, FirestoreRest } from "./firestore.js";
import type { Env, Principal } from "./index.js";
import { ApiError } from "./errors.js";
import { gatewayBase, gatewayHead, gatewayPublishPanorama, signPublishedReadCapability } from "./r2_gateway_client.js";

const LIMIT = 9_000_000_000;
const quotaPath = "system_config/storage_quota";

function currentDerivative(node: Record<string, unknown>, ownerUid: string, tourId: number): Record<string, unknown> {
  const derivative = node.verified_derivative as Record<string, unknown> | undefined;
  const review = node.owner_review as Record<string, unknown> | undefined;
  if (node.owner_reviewed !== true || !derivative || derivative.status !== "verified" || derivative.accountingState !== "counted" || derivative.contentType !== "image/jpeg" || !Number.isSafeInteger(derivative.size) || Number(derivative.size) <= 0 || typeof derivative.sha256 !== "string" || !/^[a-f0-9]{64}$/.test(derivative.sha256) || typeof derivative.revisionId !== "string" || !/^[a-f0-9]{32}$/.test(derivative.revisionId) || typeof derivative.reservationId !== "string" || derivative.objectKey !== `tours/derivatives/${ownerUid}/${tourId}/${Number(node.id)}/${derivative.revisionId}_${derivative.sha256}.jpg` || !(derivative.verifiedAt instanceof Date)) throw new ApiError(412, "Every viewpoint needs a current backend-verified derivative.");
  if (!review || review.ownerUid !== ownerUid || review.derivativeSha256 !== derivative.sha256 || review.processingVersion !== derivative.processingVersion || typeof review.processingVersion !== "string" || review.acknowledgedMissRisk !== true || review.acknowledgedManualInspection !== true || review.directionCount !== 48 || review.recordType !== "owner-attestation-not-privacy-proof" || !Array.isArray(review.inspectedDirections) || review.inspectedDirections.length !== 48 || new Set(review.inspectedDirections).size !== 48 || review.inspectedDirections.some((value, index) => value !== index) || !(review.reviewedAt instanceof Date)) throw new ApiError(412, "Every viewpoint needs the current owner's complete 48-direction attestation.");
  return derivative;
}

function quotaValid(quota: Record<string, unknown> | null): boolean {
  return Boolean(quota && quota.storageProvider === "cloudflare_r2" && quota.limitBytes === LIMIT && Number.isSafeInteger(quota.usedBytes) && Number.isSafeInteger(quota.reservedBytes) && Number(quota.usedBytes) >= 0 && Number(quota.reservedBytes) >= 0 && Number(quota.usedBytes) + Number(quota.reservedBytes) <= LIMIT);
}

async function objectLedgerPath(key: string): Promise<string> {
  const hash = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(key)));
  return `storageObjects/${Array.from(hash, (byte) => byte.toString(16).padStart(2, "0")).join("")}`;
}

async function requireTourStore(db: FirestoreRest, tourId: number) {
  const tours = await db.query("tours", [{ field: "numericId", op: "EQUAL", value: tourId }], 1);
  if (!tours.length) throw new ApiError(404, "Tour was not found.");
  const tourDoc = tours[0], tour = documentData(tourDoc)!;
  const stores = await db.query("stores", [{ field: "numericId", op: "EQUAL", value: Number(tour.storeId) }], 1);
  if (!stores.length) throw new ApiError(404, "Store was not found.");
  return { tourDoc, tourPath: tourDoc.name.split("/documents/")[1], tour, storeDoc: stores[0], storePath: stores[0].name.split("/documents/")[1], store: documentData(stores[0])! };
}

export async function publishStoreTour(request: Request, env: Env, principal: Principal): Promise<Response> {
  if (request.method !== "POST") return Response.json({ error: "Method not allowed." }, { status: 405, headers: { Allow: "POST" } });
  let data: Record<string, unknown>;
  try { const value: unknown = await request.json(); if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error(); data = value as Record<string, unknown>; }
  catch { throw new ApiError(400, "A valid JSON object is required."); }
  if (!Number.isSafeInteger(data.tourId) || Number(data.tourId) <= 0) throw new ApiError(400, "A valid tour ID is required.");
  const db = new FirestoreRest(env), uid = principal.uid, tourId = Number(data.tourId), initial = await requireTourStore(db, tourId);
  if (initial.tour.ownerUid !== uid || initial.store.ownerUid !== uid || initial.store.status !== "approved") throw new ApiError(403, "Only the authenticated store owner can publish this tour.");
  if (!Array.isArray(initial.tour.nodes) || initial.tour.nodes.length < 2 || initial.tour.status !== "draft") throw new ApiError(412, "A draft tour with at least two reviewed viewpoints is required.");
  const nodes = initial.tour.nodes as Array<Record<string, unknown>>;
  const derivatives = nodes.map((node) => ({ node, derivative: currentDerivative(node, uid, tourId) }));
  const accounting = await Promise.all(derivatives.map(async ({ derivative }) => {
    const [ledgerDoc, reservationDoc] = await Promise.all([db.get(await objectLedgerPath(String(derivative.objectKey))), db.get(`uploadReservations/${String(derivative.reservationId)}`)]);
    return { ledger: documentData(ledgerDoc), reservation: documentData(reservationDoc) };
  }));
  const quota = documentData(await db.get(quotaPath));
  if (!quotaValid(quota)) throw new ApiError(412, "R2 quota accounting is unavailable or inconsistent.");
  const objects = await Promise.all(derivatives.map(async ({ node, derivative }, index) => {
    const { ledger, reservation } = accounting[index];
    if (!ledger || ledger.accountingState !== "counted" || ledger.countedInQuota !== true || ledger.objectKey !== derivative.objectKey || Number(ledger.sizeBytes) !== Number(derivative.size) || ledger.uid !== uid || ledger.reservationId !== derivative.reservationId || !reservation || reservation.status !== "completed" || reservation.purpose !== "processed" || Number(reservation.actualBytes) !== Number(derivative.size)) throw new ApiError(412, "A panorama derivative is not finalized in the R2 quota ledger.");
    const head = await gatewayHead(env, String(derivative.objectKey));
    if (!head || head.key !== derivative.objectKey || head.size !== derivative.size || head.contentType !== "image/jpeg" || head.uid !== uid || head.mediaType !== "panorama-derivative" || head.sha256 !== derivative.sha256) throw new ApiError(412, "A stored panorama derivative no longer matches its verified metadata.");
    return { key: String(derivative.objectKey), nodeId: Number(node.id), sha256: String(derivative.sha256) };
  }));
  for (const object of objects) await gatewayPublishPanorama(env, object.key, tourId, object.nodeId, object.sha256);
  const publishedAt = new Date();
  await db.runTransaction(async (tx) => {
    const [tourDoc, storeDoc, quotaDoc, ...accountingDocs] = await Promise.all([
      tx.get(initial.tourPath), tx.get(initial.storePath), tx.get(quotaPath),
      ...derivatives.map(({ derivative }) => objectLedgerPath(String(derivative.objectKey)).then((path) => tx.get(path))),
      ...derivatives.map(({ derivative }) => tx.get(`uploadReservations/${String(derivative.reservationId)}`)),
    ]);
    const tour = documentData(tourDoc), store = documentData(storeDoc), currentQuota = documentData(quotaDoc);
    if (!tour || !store || tour.status !== "draft" || tour.ownerUid !== uid || store.ownerUid !== uid || store.status !== "approved" || !quotaValid(currentQuota) || !Array.isArray(tour.nodes)) throw new ApiError(412, "Tour ownership, draft status, or quota accounting changed during publication.");
    const currentNodes = tour.nodes as Array<Record<string, unknown>>;
    if (currentNodes.length !== derivatives.length) throw new ApiError(409, "The tour changed during publication. Retry after reviewing it again.");
    for (let index = 0; index < derivatives.length; index++) {
      const currentNode = currentNodes.find((node) => Number(node.id) === Number(derivatives[index].node.id));
      const derivative = currentNode ? currentDerivative(currentNode, uid, tourId) : null;
      const ledger = documentData(accountingDocs[index] as import("./firestore.js").FirestoreDocument | null);
      const reservation = documentData(accountingDocs[index + derivatives.length] as import("./firestore.js").FirestoreDocument | null);
      if (!derivative || derivative.objectKey !== derivatives[index].derivative.objectKey || derivative.sha256 !== derivatives[index].derivative.sha256 || derivative.revisionId !== derivatives[index].derivative.revisionId || ledger?.accountingState !== "counted" || ledger.countedInQuota !== true || reservation?.status !== "completed" || reservation.purpose !== "processed") throw new ApiError(409, "A viewpoint changed during publication. Review the current derivative again.");
    }
    tx.patch(initial.tourPath, { status: "published", publishedAt, updatedAt: publishedAt });
  });
  return Response.json({ ok: true, tourId, status: "published" }, { headers: { "Cache-Control": "no-store" } });
}

export async function getPublishedTourPanoramaAccess(request: Request, env: Env, _principal: Principal): Promise<Response> {
  if (request.method !== "POST") return Response.json({ error: "Method not allowed." }, { status: 405, headers: { Allow: "POST" } });
  let data: Record<string, unknown>;
  try { const value: unknown = await request.json(); if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error(); data = value as Record<string, unknown>; }
  catch { throw new ApiError(400, "A valid JSON object is required."); }
  if (!Number.isSafeInteger(data.tourId) || Number(data.tourId) <= 0 || !Number.isSafeInteger(data.nodeId) || Number(data.nodeId) <= 0) throw new ApiError(400, "Valid tour and viewpoint IDs are required.");
  const tourId = Number(data.tourId), nodeId = Number(data.nodeId), db = new FirestoreRest(env), { tour, store } = await requireTourStore(db, tourId);
  if (tour.status !== "published" || store.status !== "approved") throw new ApiError(404, "Published media was not found.");
  if (!Array.isArray(tour.nodes)) throw new ApiError(502, "Tour viewpoint data is invalid.");
  const node = (tour.nodes as Array<Record<string, unknown>>).find((row) => Number(row.id) === nodeId);
  if (!node) throw new ApiError(404, "Published media was not found.");
  const derivative = currentDerivative(node, String(tour.ownerUid), tourId);
  const [ledgerDoc, reservationDoc, quotaDoc, actual] = await Promise.all([
    db.get(await objectLedgerPath(String(derivative.objectKey))), db.get(`uploadReservations/${String(derivative.reservationId)}`), db.get(quotaPath), gatewayHead(env, String(derivative.objectKey)),
  ]);
  const ledger = documentData(ledgerDoc), reservation = documentData(reservationDoc), quota = documentData(quotaDoc);
  if (!ledger || ledger.accountingState !== "counted" || ledger.countedInQuota !== true || ledger.objectKey !== derivative.objectKey || Number(ledger.sizeBytes) !== Number(derivative.size) || ledger.uid !== tour.ownerUid || ledger.reservationId !== derivative.reservationId || !reservation || reservation.status !== "completed" || reservation.purpose !== "processed" || Number(reservation.actualBytes) !== Number(derivative.size) || !quotaValid(quota) || !actual || actual.key !== derivative.objectKey || actual.size !== derivative.size || actual.contentType !== "image/jpeg" || actual.uid !== tour.ownerUid || actual.mediaType !== "panorama-derivative" || actual.sha256 !== derivative.sha256 || actual.publicApproved !== "true") throw new ApiError(412, "Published derivative verification or finalized quota accounting is no longer valid.");
  const token = await signPublishedReadCapability(env, String(derivative.objectKey), tourId, nodeId, String(derivative.sha256));
  const url = new URL("/v1/media/panorama", `${gatewayBase(env)}/`);
  url.searchParams.set("key", String(derivative.objectKey));
  return Response.json({ url: url.toString(), token, expiresInSeconds: 300 }, { headers: { "Cache-Control": "no-store" } });
}
