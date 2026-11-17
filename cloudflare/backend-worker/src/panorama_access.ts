import { documentData, FirestoreRest } from "./firestore.js";
import type { Env, Principal } from "./index.js";
import { ApiError } from "./errors.js";
import { gatewayBase, gatewayHead, signPrivateReadCapability } from "./r2_gateway_client.js";

async function body(request: Request): Promise<Record<string, unknown>> {
  try { const value: unknown = await request.json(); if (value && typeof value === "object" && !Array.isArray(value)) return value as Record<string, unknown>; }
  catch { /* invalid JSON */ }
  throw new ApiError(400, "A valid JSON object is required.");
}

export async function getPanoramaPrivateMediaAccess(request: Request, env: Env, principal: Principal): Promise<Response> {
  if (request.method !== "POST") return Response.json({ error: "Method not allowed." }, { status: 405, headers: { Allow: "POST" } });
  const data = await body(request);
  if (!Number.isSafeInteger(data.tourId) || Number(data.tourId) <= 0 || !Number.isSafeInteger(data.nodeId) || Number(data.nodeId) <= 0 || !["original", "derivative"].includes(String(data.variant))) throw new ApiError(400, "Valid tour, viewpoint, and private media type are required.");
  const tourId = Number(data.tourId), nodeId = Number(data.nodeId), db = new FirestoreRest(env);
  const tours = await db.query("tours", [{ field: "numericId", op: "EQUAL", value: tourId }], 1);
  if (!tours.length) throw new ApiError(404, "Tour was not found.");
  const tour = documentData(tours[0])!;
  const stores = await db.query("stores", [{ field: "numericId", op: "EQUAL", value: Number(tour.storeId) }], 1);
  if (!stores.length) throw new ApiError(404, "Store was not found.");
  const store = documentData(stores[0])!, profile = documentData(await db.get(`users/${principal.uid}`));
  const admin = profile?.role === "admin";
  if (!profile) throw new ApiError(403, "This account is no longer active.");
  if (!admin && (tour.ownerUid !== principal.uid || store.ownerUid !== principal.uid)) throw new ApiError(403, "Only this tour's owner can access its private media.");
  if (!Array.isArray(tour.nodes)) throw new ApiError(502, "Tour viewpoint data is invalid.");
  const node = (tour.nodes as Array<Record<string, unknown>>).find((row) => Number(row.id) === nodeId);
  if (!node) throw new ApiError(404, "Private media was not found.");
  let objectKey: string;
  if (data.variant === "original") {
    objectKey = String(node.original_path ?? "");
    if (!objectKey.startsWith(`tours/originals/${String(tour.ownerUid)}/${tourId}/`)) throw new ApiError(412, "The private original is unavailable.");
  } else {
    const derivative = node.verified_derivative as Record<string, unknown> | undefined;
    if (!derivative || derivative.status !== "verified" || derivative.accountingState !== "counted") throw new ApiError(412, "The private derivative is unavailable.");
    objectKey = String(derivative.objectKey ?? "");
  }
  const actual = await gatewayHead(env, objectKey), derivative = node.verified_derivative as Record<string, unknown> | undefined;
  if (!actual || actual.key !== objectKey || actual.uid !== tour.ownerUid || actual.size <= 0 || actual.contentType !== "image/jpeg" ||
      (data.variant === "original" ? actual.mediaType !== "panorama" : actual.mediaType !== "panorama-derivative" || actual.sha256 !== derivative?.sha256)) throw new ApiError(404, "Private media was not found.");
  const token = await signPrivateReadCapability(env, objectKey, principal.uid), url = new URL("/v1/media/private", `${gatewayBase(env)}/`);
  url.searchParams.set("key", objectKey);
  return Response.json({ url: url.toString(), token, expiresInSeconds: 300, contentType: actual.contentType }, { headers: { "Cache-Control": "no-store" } });
}
