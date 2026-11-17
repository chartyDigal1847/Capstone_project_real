import { documentData, FirestoreRest } from "./firestore.js";
import type { Env, Principal } from "./index.js";
import { ApiError } from "./errors.js";
import { gatewayBase, signPrivateReadCapability } from "./r2_gateway_client.js";

async function body(request: Request): Promise<Record<string, unknown>> {
  try { const value: unknown = await request.json(); if (value && typeof value === "object" && !Array.isArray(value)) return value as Record<string, unknown>; }
  catch { /* invalid JSON */ }
  throw new ApiError(400, "A valid JSON object is required.");
}

export async function getPrivateMediaAccess(request: Request, env: Env, principal: Principal): Promise<Response> {
  if (request.method !== "POST") return Response.json({ error: "Method not allowed." }, { status: 405, headers: { Allow: "POST" } });
  const data = await body(request);
  if (typeof data.assetId !== "string" || !/^[A-Za-z0-9_-]{1,100}$/.test(data.assetId)) throw new ApiError(400, "A valid media ID is required.");
  const db = new FirestoreRest(env), caller = documentData(await db.get(`users/${principal.uid}`));
  if (!caller) throw new ApiError(403, "This account is no longer active.");
  const admin = caller.role === "admin";
  const targetUid = admin && typeof data.uid === "string" ? data.uid : principal.uid;
  const media = documentData(await db.get(`mediaAssets/${targetUid}_${data.assetId}`));
  if (!media) throw new ApiError(404, "Private media was not found.");
  if (!admin && media.uid !== principal.uid) throw new ApiError(403, "You cannot view this media.");
  if (!["store", "panorama"].includes(String(media.mediaType))) throw new ApiError(412, "This media is not private.");
  const objectKey = media.mediaType === "panorama" ? media.originalPath : media.privatePath;
  if (typeof objectKey !== "string" || !["ready", "awaiting-privacy-processing"].includes(String(media.status))) throw new ApiError(412, "Private media is not ready to view.");
  const token = await signPrivateReadCapability(env, objectKey, principal.uid);
  const url = new URL("/v1/media/private", `${gatewayBase(env)}/`);
  url.searchParams.set("key", objectKey);
  return Response.json({ url: url.toString(), token }, { headers: { "Cache-Control": "no-store" } });
}
