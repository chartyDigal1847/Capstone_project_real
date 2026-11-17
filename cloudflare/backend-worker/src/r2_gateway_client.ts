import { importJWK, SignJWT } from "jose";
import type { Env } from "./index.js";
import { ApiError } from "./errors.js";

const ISSUER = "localspot-functions";
const AUDIENCE = "locentra-upload-gateway";
const keyPath = "/v1/internal/object";

function baseUrl(env: Env): string {
  const raw = env.R2_GATEWAY_URL?.trim().replace(/\/+$/, "");
  if (!raw) throw new ApiError(503, "R2 storage gateway is not configured.");
  let url: URL;
  try { url = new URL(raw); }
  catch { throw new ApiError(503, "R2 storage gateway configuration is invalid."); }
  if (url.username || url.password || url.pathname !== "/" || url.search || url.hash) {
    throw new ApiError(503, "R2 storage gateway configuration is invalid.");
  }
  if (url.protocol === "https:") return url.origin;
  if (env.LOCAL_EMULATORS !== "true" || url.protocol !== "http:" || !isPrivateEmulatorHost(url.hostname)) {
    throw new ApiError(503, "R2 storage gateway configuration is invalid.");
  }
  return url.origin;
}

export function isPrivateEmulatorHost(hostname: string): boolean {
  const host = hostname.toLowerCase().replace(/^\[|\]$/g, "");
  if (host === "localhost" || host === "::1" || host === "127.0.0.1") return true;
  const octets = host.split(".").map(Number);
  if (octets.length !== 4 || octets.some((value) => !Number.isInteger(value) || value < 0 || value > 255)) return false;
  const [first, second] = octets;
  return first === 10 || (first === 192 && second === 168) ||
    (first === 172 && second >= 16 && second <= 31);
}

async function gatewayToken(env: Env, scope: string, objectKey?: string): Promise<string> {
  if (!env.R2_GATEWAY_PRIVATE_JWK) throw new ApiError(503, "R2 storage signing key is not configured.");
  let jwk: JsonWebKey & { kid?: string; d?: string };
  try { jwk = JSON.parse(env.R2_GATEWAY_PRIVATE_JWK) as JsonWebKey & { kid?: string; d?: string }; }
  catch { throw new ApiError(503, "R2 storage signing key is invalid."); }
  if (jwk.kty !== "EC" || jwk.crv !== "P-256" || typeof jwk.d !== "string" || !jwk.kid) throw new ApiError(503, "R2 storage signing key is invalid.");
  const key = await importJWK(jwk, "ES256");
  const now = Math.floor(Date.now() / 1000);
  return new SignJWT({ scope, ...(objectKey ? { objectKey } : {}) })
    .setProtectedHeader({ alg: "ES256", typ: "JWT", kid: jwk.kid })
    .setIssuer(ISSUER).setAudience(AUDIENCE).setSubject(ISSUER)
    .setJti(crypto.randomUUID()).setIssuedAt(now).setExpirationTime(now + 300).sign(key);
}

export async function signUploadCapability(env: Env, claims: Record<string, unknown>, uid: string, reservationId: string): Promise<string> {
  if (!env.R2_GATEWAY_PRIVATE_JWK) throw new ApiError(503, "R2 storage signing key is not configured.");
  let jwk: JsonWebKey & { kid?: string; d?: string };
  try { jwk = JSON.parse(env.R2_GATEWAY_PRIVATE_JWK) as JsonWebKey & { kid?: string; d?: string }; }
  catch { throw new ApiError(503, "R2 storage signing key is invalid."); }
  if (jwk.kty !== "EC" || jwk.crv !== "P-256" || typeof jwk.d !== "string" || !jwk.kid) throw new ApiError(503, "R2 storage signing key is invalid.");
  const key = await importJWK(jwk, "ES256");
  const now = Math.floor(Date.now() / 1000);
  return new SignJWT({ ...claims, iss: ISSUER, aud: AUDIENCE, sub: uid, iat: now, exp: now + 300, jti: reservationId })
    .setProtectedHeader({ alg: "ES256", typ: "JWT", kid: jwk.kid }).sign(key);
}

export async function signPrivateReadCapability(env: Env, objectKey: string, uid: string): Promise<string> {
  if (!env.R2_GATEWAY_PRIVATE_JWK) throw new ApiError(503, "R2 storage signing key is not configured.");
  let jwk: JsonWebKey & { kid?: string; d?: string };
  try { jwk = JSON.parse(env.R2_GATEWAY_PRIVATE_JWK) as JsonWebKey & { kid?: string; d?: string }; }
  catch { throw new ApiError(503, "R2 storage signing key is invalid."); }
  if (jwk.kty !== "EC" || jwk.crv !== "P-256" || typeof jwk.d !== "string" || !jwk.kid) throw new ApiError(503, "R2 storage signing key is invalid.");
  const key = await importJWK(jwk, "ES256"), now = Math.floor(Date.now() / 1000);
  return new SignJWT({ scope: "media:read", objectKey }).setProtectedHeader({ alg: "ES256", typ: "JWT", kid: jwk.kid })
    .setIssuer(ISSUER).setAudience(AUDIENCE).setSubject(uid).setJti(crypto.randomUUID()).setIssuedAt(now).setExpirationTime(now + 300).sign(key);
}

export function gatewayBase(env: Env): string { return baseUrl(env); }

async function gatewayFetch(env: Env, url: URL, init: RequestInit): Promise<Response> {
  const request = new Request(url, init);
  return env.R2_GATEWAY ? env.R2_GATEWAY.fetch(request) : fetch(request);
}

export function gatewayPublicMediaUrl(env: Env, key: string): string {
  return `${baseUrl(env)}/v1/media/public/${encodeURIComponent(key)}`;
}

export async function gatewayListPage(env: Env, cursor?: string, limit = 1000): Promise<{ objects: Array<{ key: string; size: number; etag: string; uploadedAt: string; customMetadata: Record<string, string> }>; truncated: boolean; cursor: string | null }> {
  const url = new URL("/v1/internal/objects", `${baseUrl(env)}/`);
  url.searchParams.set("limit", String(limit));
  if (cursor) url.searchParams.set("cursor", cursor);
  let response: Response;
  try {
    response = await gatewayFetch(env, url, { headers: { "X-Gateway-Authorization": `Bearer ${await gatewayToken(env, "objects:list")}` }, signal: AbortSignal.timeout(15_000) });
  } catch { throw new ApiError(503, "R2 storage gateway is unavailable."); }
  if (!response.ok) {
    const failure = await response.json().catch(() => ({})) as { error?: unknown };
    const reason = typeof failure.error === "string" ? failure.error.slice(0, 160) : "unspecified gateway error";
    console.warn("R2 gateway inventory request was rejected", {
      status: response.status,
      reason,
    });
    throw new ApiError(503, `R2 inventory listing failed (${response.status}: ${reason}).`);
  }
  const body = await response.json() as { objects?: Array<{ key: string; size: number; etag: string; uploadedAt: string; customMetadata: Record<string, string> }>; truncated?: boolean; cursor?: string | null };
  if (!Array.isArray(body.objects) || typeof body.truncated !== "boolean") throw new ApiError(502, "R2 returned an invalid inventory page.");
  return { objects: body.objects, truncated: body.truncated, cursor: body.cursor ?? null };
}

export interface GatewayObject {
  key: string;
  size: number;
  contentType: string;
  reservationId: string | null;
  uid: string | null;
  mediaType: string | null;
  sha256: string | null;
  verifiedSha256: string | null;
  publicApproved: string | null;
}

export async function gatewayHead(env: Env, objectKey: string): Promise<GatewayObject | null> {
  const url = new URL(keyPath, `${baseUrl(env)}/`);
  url.searchParams.set("key", objectKey);
  let response: Response;
  try {
    response = await gatewayFetch(env, url, { method: "HEAD", headers: { "X-Gateway-Authorization": `Bearer ${await gatewayToken(env, "object:head", objectKey)}` }, signal: AbortSignal.timeout(8_000) });
  } catch { throw new ApiError(503, "R2 storage gateway is unavailable."); }
  if (response.status === 404) return null;
  if (!response.ok) throw new ApiError(503, "R2 object verification failed.");
  const size = Number(response.headers.get("Content-Length"));
  if (!Number.isSafeInteger(size) || size < 0) throw new ApiError(502, "R2 returned invalid object metadata.");
  return { key: objectKey, size, contentType: response.headers.get("Content-Type") ?? "application/octet-stream", reservationId: response.headers.get("X-Object-Reservation-Id"), uid: response.headers.get("X-Object-Uid"), mediaType: response.headers.get("X-Object-Media-Type"), sha256: response.headers.get("X-Object-Sha256"), verifiedSha256: response.headers.get("X-Object-Verified-Sha256"), publicApproved: response.headers.get("X-Object-Public-Approved") };
}

export async function gatewayDelete(env: Env, objectKey: string): Promise<{ existed: boolean }> {
  const url = new URL(keyPath, `${baseUrl(env)}/`);
  url.searchParams.set("key", objectKey);
  let response: Response;
  try {
    response = await gatewayFetch(env, url, { method: "DELETE", headers: { "X-Gateway-Authorization": `Bearer ${await gatewayToken(env, "object:delete", objectKey)}` }, signal: AbortSignal.timeout(8_000) });
  } catch { throw new ApiError(503, "R2 storage gateway is unavailable."); }
  if (!response.ok) throw new ApiError(503, "R2 object deletion was not confirmed.");
  const result = await response.json() as { deleted?: unknown; existed?: unknown };
  if (result.deleted !== true || typeof result.existed !== "boolean") throw new ApiError(502, "R2 did not confirm object deletion.");
  return { existed: result.existed };
}

export async function gatewayRead(env: Env, objectKey: string): Promise<Uint8Array> {
  const url = new URL(keyPath, `${baseUrl(env)}/`);
  url.searchParams.set("key", objectKey);
  let response: Response;
  try { response = await gatewayFetch(env, url, { headers: { "X-Gateway-Authorization": `Bearer ${await gatewayToken(env, "object:get", objectKey)}` }, signal: AbortSignal.timeout(20_000) }); }
  catch { throw new ApiError(503, "R2 storage gateway is unavailable."); }
  if (!response.ok) throw new ApiError(response.status === 404 ? 404 : 503, "The uploaded R2 object could not be read.");
  return new Uint8Array(await response.arrayBuffer());
}

export async function gatewayPut(env: Env, key: string, bytes: Uint8Array, contentType: string, metadata: { reservationId: string; uid: string; mediaType: string }): Promise<void> {
  const url = new URL(keyPath, `${baseUrl(env)}/`);
  url.searchParams.set("key", key);
  let response: Response;
  // The gateway authorizes output metadata from signed claims; make a token with the fields it persists.
  const richToken = await signInternalPutCapability(env, key, bytes.byteLength, contentType, metadata);
  try {
    response = await gatewayFetch(env, url, { method: "PUT", headers: { "X-Gateway-Authorization": `Bearer ${richToken}`, "Content-Type": contentType, "Content-Length": String(bytes.byteLength) }, body: bytes.slice().buffer as ArrayBuffer, signal: AbortSignal.timeout(20_000) });
  } catch { throw new ApiError(503, "R2 storage gateway is unavailable."); }
  if (!response.ok) throw new ApiError(response.status === 409 ? 409 : 503, "The processed R2 object could not be stored.");
}

export async function gatewayPublishPanorama(env: Env, key: string, tourId: number, nodeId: number, sha256: string): Promise<void> {
  const url = new URL("/v1/internal/publish", `${baseUrl(env)}/`);
  url.searchParams.set("key", key);
  const token = await signInternalPublishCapability(env, key, tourId, nodeId, sha256);
  let response: Response;
  try { response = await gatewayFetch(env, url, { method: "POST", headers: { "X-Gateway-Authorization": `Bearer ${token}` }, signal: AbortSignal.timeout(10_000) }); }
  catch { throw new ApiError(503, "R2 storage gateway is unavailable."); }
  if (!response.ok) throw new ApiError(503, "The panorama derivative could not be published in R2.");
  const result = await response.json() as { published?: unknown; key?: unknown; sha256?: unknown; size?: unknown };
  if (result.published !== true || result.key !== key || result.sha256 !== sha256 || !Number.isSafeInteger(result.size)) throw new ApiError(502, "R2 did not confirm panorama publication.");
}

export async function gatewayPublishStoreImage(env: Env, key: string): Promise<void> {
  const url = new URL("/v1/internal/publish", `${baseUrl(env)}/`);
  url.searchParams.set("key", key);
  let response: Response;
  try {
    response = await gatewayFetch(env, url, { method: "POST", headers: { "X-Gateway-Authorization": `Bearer ${await gatewayToken(env, "object:publish", key)}` }, signal: AbortSignal.timeout(10_000) });
  } catch {
    throw new ApiError(503, "R2 storage gateway is unavailable.");
  }
  if (!response.ok) throw new ApiError(503, "The store image could not be published in R2.");
  const result = await response.json() as { published?: unknown; size?: unknown; key?: unknown };
  if (result.published !== true || result.key !== key || !Number.isSafeInteger(result.size)) throw new ApiError(502, "R2 did not confirm store image publication.");
}

export async function signPublishedReadCapability(env: Env, objectKey: string, tourId: number, nodeId: number, derivativeSha256: string): Promise<string> {
  if (!env.R2_GATEWAY_PRIVATE_JWK) throw new ApiError(503, "R2 storage signing key is not configured.");
  let jwk: JsonWebKey & { kid?: string; d?: string };
  try { jwk = JSON.parse(env.R2_GATEWAY_PRIVATE_JWK) as JsonWebKey & { kid?: string; d?: string }; }
  catch { throw new ApiError(503, "R2 storage signing key is invalid."); }
  if (jwk.kty !== "EC" || jwk.crv !== "P-256" || typeof jwk.d !== "string" || !jwk.kid) throw new ApiError(503, "R2 storage signing key is invalid.");
  const key = await importJWK(jwk, "ES256"), now = Math.floor(Date.now() / 1000);
  return new SignJWT({ scope: "media:public-read", objectKey, tourId, nodeId, derivativeSha256 }).setProtectedHeader({ alg: "ES256", typ: "JWT", kid: jwk.kid })
    .setIssuer(ISSUER).setAudience(AUDIENCE).setSubject(ISSUER).setJti(crypto.randomUUID()).setIssuedAt(now).setExpirationTime(now + 300).sign(key);
}

async function signInternalPublishCapability(env: Env, objectKey: string, tourId: number, nodeId: number, derivativeSha256: string): Promise<string> {
  if (!env.R2_GATEWAY_PRIVATE_JWK) throw new ApiError(503, "R2 storage signing key is not configured.");
  let jwk: JsonWebKey & { kid?: string; d?: string };
  try { jwk = JSON.parse(env.R2_GATEWAY_PRIVATE_JWK) as JsonWebKey & { kid?: string; d?: string }; }
  catch { throw new ApiError(503, "R2 storage signing key is invalid."); }
  if (jwk.kty !== "EC" || jwk.crv !== "P-256" || typeof jwk.d !== "string" || !jwk.kid) throw new ApiError(503, "R2 storage signing key is invalid.");
  const key = await importJWK(jwk, "ES256"), now = Math.floor(Date.now() / 1000);
  return new SignJWT({ scope: "object:publish", objectKey, tourId, nodeId, derivativeSha256 }).setProtectedHeader({ alg: "ES256", typ: "JWT", kid: jwk.kid })
    .setIssuer(ISSUER).setAudience(AUDIENCE).setSubject(ISSUER).setJti(crypto.randomUUID()).setIssuedAt(now).setExpirationTime(now + 300).sign(key);
}

async function signInternalPutCapability(env: Env, objectKey: string, maxBytes: number, contentType: string, metadata: { reservationId: string; uid: string; mediaType: string }): Promise<string> {
  if (!env.R2_GATEWAY_PRIVATE_JWK) throw new ApiError(503, "R2 storage signing key is not configured.");
  let jwk: JsonWebKey & { kid?: string; d?: string };
  try { jwk = JSON.parse(env.R2_GATEWAY_PRIVATE_JWK) as JsonWebKey & { kid?: string; d?: string }; }
  catch { throw new ApiError(503, "R2 storage signing key is invalid."); }
  if (jwk.kty !== "EC" || jwk.crv !== "P-256" || typeof jwk.d !== "string" || !jwk.kid) throw new ApiError(503, "R2 storage signing key is invalid.");
  const key = await importJWK(jwk, "ES256"), now = Math.floor(Date.now() / 1000);
  return new SignJWT({ scope: "object:put", objectKey, maxBytes, contentType, ...metadata, publicApproved: false })
    .setProtectedHeader({ alg: "ES256", typ: "JWT", kid: jwk.kid }).setIssuer(ISSUER).setAudience(AUDIENCE).setSubject(ISSUER).setJti(crypto.randomUUID()).setIssuedAt(now).setExpirationTime(now + 300).sign(key);
}
