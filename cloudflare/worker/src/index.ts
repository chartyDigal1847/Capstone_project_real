import { createLocalJWKSet, importX509, jwtVerify, type JWTPayload } from "jose";

const FIREBASE_CERT_URL = "https://www.googleapis.com/robot/v1/metadata/x509/securetoken@system.gserviceaccount.com";
const GATEWAY_ISSUER = "localspot-functions";
const GATEWAY_AUDIENCE = "locentra-upload-gateway";
const TOKEN_MAX_LIFETIME_SECONDS = 5 * 60;
const IMAGE_MAX_BYTES = 8 * 1024 * 1024;
const PANORAMA_MAX_BYTES = 50 * 1024 * 1024;
const IMAGE_TYPES = new Set(["image/jpeg", "image/png", "image/webp"]);
const CACHE_CONTROL_PUBLIC = "public,max-age=86400";
const CACHE_CONTROL_PRIVATE = "private,no-store";
const NO_CACHE_HEADERS = {
  "Cache-Control": "no-store",
  "X-Content-Type-Options": "nosniff",
};

interface Env {
  MEDIA_BUCKET: R2Bucket;
  FIREBASE_PROJECT_ID: string;
  /** Development-only Auth Emulator endpoint; loopback-only and never configured for deployment. */
  FIREBASE_AUTH_EMULATOR_URL?: string;
  /** Public ES256 verification keys, encoded as a JSON JWK set. Private keys belong in Firebase Secret Manager. */
  GATEWAY_PUBLIC_JWKS?: string;
}

interface UploadClaims extends JWTPayload {
  sub: string;
  scope: "upload";
  objectKey: string;
  contentType: string;
  maxBytes: number;
  mediaType: "product" | "store" | "panorama" | "panorama-derivative";
  assetId: string;
  tourId?: number;
  nodeId?: number;
  revisionId?: string;
  derivativeSha256?: string;
}

class HttpError extends Error {
  constructor(readonly status: number, message: string) {
    super(message);
  }
}

let firebaseCerts: { keys: Record<string, string>; expiresAt: number } | undefined;
let gatewayKeySet: { serialized: string; key: ReturnType<typeof createLocalJWKSet> } | undefined;

function json(data: unknown, status = 200, headers: HeadersInit = {}): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8", ...headers },
  });
}

function errorResponse(error: unknown): Response {
  if (error instanceof HttpError) return json({ error: error.message }, error.status, NO_CACHE_HEADERS);
  console.error("R2 gateway request failed", { errorType: error instanceof Error ? error.name : "unknown" });
  return json({ error: "The storage request could not be completed." }, 500, NO_CACHE_HEADERS);
}

function requiredBearer(headers: Headers, name = "Authorization"): string {
  const value = headers.get(name);
  const match = value?.match(/^Bearer ([A-Za-z0-9._~-]+)$/);
  if (!match) throw new HttpError(401, "A valid bearer token is required.");
  return match[1];
}

async function loadFirebaseCerts(): Promise<Record<string, string>> {
  if (firebaseCerts && firebaseCerts.expiresAt > Date.now()) return firebaseCerts.keys;
  let response: Response;
  try {
    response = await fetch(FIREBASE_CERT_URL);
  } catch {
    throw new HttpError(503, "Firebase token verification is temporarily unavailable.");
  }
  if (!response.ok) throw new HttpError(503, "Firebase token verification is temporarily unavailable.");
  const parsed: unknown = await response.json();
  if (parsed == null || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new HttpError(503, "Firebase token verification is temporarily unavailable.");
  }
  const keys = parsed as Record<string, string>;
  const cacheControl = response.headers.get("Cache-Control") ?? "";
  const maxAge = Number(cacheControl.match(/(?:^|,)\s*max-age=(\d+)/i)?.[1] ?? 300);
  firebaseCerts = { keys, expiresAt: Date.now() + Math.max(0, maxAge) * 1000 };
  return keys;
}

async function verifyFirebaseIdToken(token: string, projectId: string): Promise<string> {
  let payload: JWTPayload;
  try {
    const header = JSON.parse(atob(token.split(".")[0].replace(/-/g, "+").replace(/_/g, "/"))) as { kid?: unknown; alg?: unknown };
    if (header.alg !== "RS256" || typeof header.kid !== "string") throw new HttpError(401, "The Firebase token is invalid.");
    const certificate = (await loadFirebaseCerts())[header.kid];
    if (!certificate) throw new HttpError(401, "The Firebase token is invalid.");
    const key = await importX509(certificate, "RS256");
    ({ payload } = await jwtVerify(token, key, {
      algorithms: ["RS256"],
      audience: projectId,
      issuer: `https://securetoken.google.com/${projectId}`,
      requiredClaims: ["sub", "iat", "exp", "auth_time"],
    }));
  } catch (error) {
    if (error instanceof HttpError) throw error;
    if (error instanceof TypeError && error.message.includes("fetch")) {
      throw new HttpError(503, "Firebase token verification is temporarily unavailable.");
    }
    throw new HttpError(401, "The Firebase token is invalid or expired.");
  }
  const now = Math.floor(Date.now() / 1000);
  if (typeof payload.sub !== "string" || !payload.sub || payload.sub.length > 128 ||
      typeof payload.iat !== "number" || payload.iat > now + 30 ||
      typeof payload.auth_time !== "number" || payload.auth_time > now + 30) {
    throw new HttpError(401, "The Firebase token is invalid or expired.");
  }
  return payload.sub;
}

function publicGatewayKeySet(env: Env): ReturnType<typeof createLocalJWKSet> {
  const serialized = env.GATEWAY_PUBLIC_JWKS;
  if (!serialized) throw new HttpError(503, "Gateway authorization keys are not configured.");
  if (gatewayKeySet?.serialized === serialized) return gatewayKeySet.key;
  try {
    const jwks: unknown = JSON.parse(serialized);
    if (jwks == null || typeof jwks !== "object" || !Array.isArray((jwks as { keys?: unknown }).keys) ||
        (jwks as { keys: unknown[] }).keys.length === 0) {
      throw new Error("JWKS has no verification keys");
    }
    const key = createLocalJWKSet(jwks as Parameters<typeof createLocalJWKSet>[0]);
    gatewayKeySet = { serialized, key };
    return key;
  } catch {
    throw new HttpError(503, "Gateway authorization keys are not configured correctly.");
  }
}

async function verifyGatewayToken(token: string, env: Env): Promise<JWTPayload> {
  try {
    const { payload } = await jwtVerify(token, publicGatewayKeySet(env), {
      algorithms: ["ES256"],
      issuer: GATEWAY_ISSUER,
      audience: GATEWAY_AUDIENCE,
      requiredClaims: ["sub", "iat", "exp", "jti", "scope"],
    });
    const now = Math.floor(Date.now() / 1000);
    if (typeof payload.sub !== "string" || !payload.sub || typeof payload.iat !== "number" ||
        payload.iat > now + 30 || now - payload.iat > TOKEN_MAX_LIFETIME_SECONDS ||
        typeof payload.exp !== "number" || payload.exp - payload.iat > TOKEN_MAX_LIFETIME_SECONDS ||
        payload.exp - now > TOKEN_MAX_LIFETIME_SECONDS) {
      throw new HttpError(401, "The gateway authorization is invalid or expired.");
    }
    return payload;
  } catch (error) {
    if (error instanceof HttpError) throw error;
    if (error instanceof TypeError && error.message.includes("Gateway authorization keys")) {
      throw error;
    }
    throw new HttpError(401, "The gateway authorization is invalid or expired.");
  }
}

async function verifyFirebaseEmulatorToken(token: string, projectId: string, emulatorOrigin: string): Promise<string> {
  let endpoint: URL;
  try {
    endpoint = new URL(emulatorOrigin);
  } catch {
    throw new HttpError(503, "Firebase Auth Emulator configuration is invalid.");
  }
  if (projectId !== "demo-localspot" || endpoint.protocol !== "http:" ||
      !["127.0.0.1", "localhost", "::1"].includes(endpoint.hostname)) {
    throw new HttpError(503, "Firebase Auth Emulator configuration is invalid.");
  }
  let response: Response;
  try {
    response = await fetch(new URL("/identitytoolkit.googleapis.com/v1/accounts:lookup?key=emulator", endpoint), {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ idToken: token }),
    });
  } catch {
    throw new HttpError(503, "Firebase Auth Emulator is temporarily unavailable.");
  }
  if (!response.ok) throw new HttpError(401, "The Firebase token is invalid or expired.");
  const result: unknown = await response.json();
  const users = result != null && typeof result === "object" && !Array.isArray(result)
    ? (result as { users?: unknown }).users
    : undefined;
  const user = Array.isArray(users) ? users[0] : undefined;
  if (user == null || typeof user !== "object" || typeof (user as { localId?: unknown }).localId !== "string") {
    throw new HttpError(401, "The Firebase token is invalid or expired.");
  }
  return (user as { localId: string }).localId;
}

async function authenticateUser(request: Request, env: Env): Promise<string> {
  const token = requiredBearer(request.headers);
  return env.FIREBASE_AUTH_EMULATOR_URL
    ? verifyFirebaseEmulatorToken(token, env.FIREBASE_PROJECT_ID, env.FIREBASE_AUTH_EMULATOR_URL)
    : verifyFirebaseIdToken(token, env.FIREBASE_PROJECT_ID);
}

async function authorize(request: Request, env: Env, expectedScope: string): Promise<JWTPayload> {
  const payload = await verifyGatewayToken(requiredBearer(request.headers, "X-Gateway-Authorization"), env);
  if (payload.scope !== expectedScope) throw new HttpError(403, "This authorization cannot perform the requested operation.");
  return payload;
}

function uidIsSafe(uid: string): boolean {
  return /^[A-Za-z0-9_-]{1,128}$/.test(uid);
}

function assetIdIsSafe(assetId: string): boolean {
  return /^[A-Za-z0-9_-]{1,128}$/.test(assetId);
}

function isManagedKey(key: string): boolean {
  if (key.length < 1 || key.length > 1024 || key.includes("\\") || key.startsWith("/")) return false;
  if (key.split("/").some((segment) => !segment || segment === "." || segment === "..")) return false;
  const uid = "[A-Za-z0-9_-]{1,128}";
  const asset = "[A-Za-z0-9_-]{1,128}";
  const image = `${asset}\\.(?:jpg|png|webp)`;
  const derivative = `${uid}/[1-9][0-9]{0,15}/[1-9][0-9]{0,15}/[A-Za-z0-9_-]{16,64}_[a-f0-9]{64}\\.jpg`;
  return new RegExp(`^(?:products/quarantine/${uid}/${asset}|products/public/${uid}/${image}|stores/quarantine/${uid}/${asset}|stores/processed/${uid}/${image}|stores/public/[0-9]{1,20}/${image}|tours/originals/${uid}/[1-9][0-9]{0,15}/${asset}|tours/derivatives/${derivative})$`).test(key);
}

function isSafeObjectKey(key: string): boolean {
  return key.length > 0 && key.length <= 1024 && !key.includes("\\") && !key.startsWith("/") &&
    key.split("/").every((segment) => segment.length > 0 && segment !== "." && segment !== "..");
}

function uploadObjectKey(payload: UploadClaims): string {
  if (!uidIsSafe(payload.sub) || !assetIdIsSafe(payload.assetId)) {
    throw new HttpError(401, "The upload authorization is invalid.");
  }
  if (payload.mediaType === "product" || payload.mediaType === "store") {
    return `${payload.mediaType === "product" ? "products" : "stores"}/quarantine/${payload.sub}/${payload.assetId}`;
  }
  if (payload.mediaType === "panorama" && Number.isSafeInteger(payload.tourId) && Number(payload.tourId) > 0) {
    return `tours/originals/${payload.sub}/${payload.tourId}/${payload.assetId}`;
  }
  if (payload.mediaType === "panorama-derivative" && Number.isSafeInteger(payload.tourId) && Number(payload.tourId) > 0 &&
      Number.isSafeInteger(payload.nodeId) && Number(payload.nodeId) > 0 &&
      typeof payload.revisionId === "string" && /^[A-Za-z0-9_-]{16,64}$/.test(payload.revisionId) &&
      typeof payload.derivativeSha256 === "string" && /^[a-f0-9]{64}$/.test(payload.derivativeSha256)) {
    return `tours/derivatives/${payload.sub}/${payload.tourId}/${payload.nodeId}/${payload.revisionId}_${payload.derivativeSha256}.jpg`;
  }
  throw new HttpError(401, "The upload authorization is invalid.");
}

function signatureLength(contentType: string): number {
  if (contentType === "image/jpeg") return 3;
  if (contentType === "image/png") return 8;
  return 12;
}

function hasImageSignature(bytes: Uint8Array, contentType: string): boolean {
  if (contentType === "image/jpeg") return bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff;
  if (contentType === "image/png") return bytes.length >= 8 && [137, 80, 78, 71, 13, 10, 26, 10].every((value, index) => bytes[index] === value);
  return bytes.length >= 12 &&
    new TextDecoder().decode(bytes.subarray(0, 4)) === "RIFF" &&
    new TextDecoder().decode(bytes.subarray(8, 12)) === "WEBP";
}

function checkedUploadStream(body: ReadableStream<Uint8Array>, contentLength: number, maxBytes: number, contentType: string): ReadableStream<Uint8Array> {
  let prefix = new Uint8Array(0);
  let signatureChecked = false;
  let actualBytes = 0;
  const validator = new TransformStream<Uint8Array, Uint8Array>({
    transform(chunk, controller) {
      actualBytes += chunk.byteLength;
      if (actualBytes > maxBytes) throw new HttpError(413, "The upload exceeds its reserved size.");
      if (signatureChecked) {
        controller.enqueue(chunk);
        return;
      }
      const combined = new Uint8Array(prefix.length + chunk.length);
      combined.set(prefix);
      combined.set(chunk, prefix.length);
      const required = signatureLength(contentType);
      if (combined.length < required) {
        prefix = combined;
        return;
      }
      if (!hasImageSignature(combined, contentType)) throw new HttpError(415, "The file signature does not match its image type.");
      signatureChecked = true;
      controller.enqueue(combined);
    },
    flush(controller) {
      if (!signatureChecked) {
        if (!hasImageSignature(prefix, contentType)) throw new HttpError(415, "The file signature does not match its image type.");
        controller.enqueue(prefix);
      }
      if (actualBytes !== contentLength) throw new HttpError(400, "The received file size does not match Content-Length.");
    },
  });
  // FixedLengthStream gives R2 a known-length body while rejecting short or long streams.
  return body.pipeThrough(validator).pipeThrough(new FixedLengthStream(contentLength));
}

function uploadLimit(payload: UploadClaims): number {
  const isPanorama = payload.mediaType === "panorama" || payload.mediaType === "panorama-derivative";
  const expectedLimit = isPanorama ? PANORAMA_MAX_BYTES : IMAGE_MAX_BYTES;
  if (!Number.isSafeInteger(payload.maxBytes) || payload.maxBytes < 1 || payload.maxBytes > expectedLimit) {
    throw new HttpError(401, "The upload authorization is invalid.");
  }
  if (payload.mediaType === "panorama-derivative" && payload.contentType !== "image/jpeg") {
    throw new HttpError(415, "Panorama derivatives must be JPEG images.");
  }
  if (!IMAGE_TYPES.has(payload.contentType)) throw new HttpError(415, "Use a JPEG, PNG, or WebP image.");
  return payload.maxBytes;
}

async function upload(request: Request, env: Env, reservationId: string): Promise<Response> {
  const uid = await authenticateUser(request, env);
  const payload = await verifyGatewayToken(requiredBearer(request.headers, "X-Upload-Authorization"), env) as UploadClaims;
  if (payload.scope !== "upload" || payload.sub !== uid || payload.jti !== reservationId ||
      !/^[A-Za-z0-9_-]{16,128}$/.test(reservationId)) {
    throw new HttpError(403, "The upload authorization does not match this request.");
  }
  const key = uploadObjectKey(payload);
  const maxBytes = uploadLimit(payload);
  if (payload.objectKey !== key) throw new HttpError(403, "The upload authorization has an invalid object key.");

  const contentType = request.headers.get("Content-Type")?.split(";", 1)[0].trim().toLowerCase();
  const contentLength = Number(request.headers.get("Content-Length"));
  if (contentType !== payload.contentType) throw new HttpError(415, "The content type does not match the reservation.");
  if (!Number.isSafeInteger(contentLength) || contentLength < 1 || contentLength > maxBytes) {
    throw new HttpError(413, "The upload size is missing or exceeds its reservation.");
  }
  if (!request.body) throw new HttpError(400, "An upload body is required.");

  let stored: R2Object | null;
  try {
    stored = await env.MEDIA_BUCKET.put(key, checkedUploadStream(request.body, contentLength, maxBytes, payload.contentType), {
      onlyIf: { etagDoesNotMatch: "*" },
      httpMetadata: { contentType: payload.contentType, cacheControl: "private,no-store" },
      customMetadata: {
        reservationId,
        uid,
        mediaType: payload.mediaType,
        state: "quarantined",
        ...(payload.mediaType === "panorama-derivative" && typeof payload.derivativeSha256 === "string"
          ? { sha256: payload.derivativeSha256, publicApproved: "false" }
          : {}),
      },
    });
  } catch (error) {
    if (error instanceof HttpError) throw error;
    throw new HttpError(400, "The upload body could not be stored.");
  }
  if (!stored) throw new HttpError(409, "This upload reservation has already been used.");
  if (stored.size > maxBytes || stored.size !== contentLength) {
    await env.MEDIA_BUCKET.delete(key);
    if (await env.MEDIA_BUCKET.head(key)) throw new HttpError(503, "An oversized object could not be cleaned up.");
    throw new HttpError(413, "The actual upload size exceeded its reservation.");
  }
  return json({ uploaded: true, reservationId, bytes: stored.size }, 201, NO_CACHE_HEADERS);
}

function objectResponse(object: R2ObjectBody, cacheControl: string, request: Request): Response {
  const headers = new Headers({
    "Content-Type": object.httpMetadata?.contentType ?? "application/octet-stream",
    "Content-Length": String(object.size),
    "Cache-Control": cacheControl,
    "X-Content-Type-Options": "nosniff",
    ETag: object.httpEtag,
  });
  if (request.method === "HEAD") return new Response(null, { status: 200, headers });
  return new Response(object.body, { status: 200, headers });
}

function queryKey(url: URL, managed = true): string {
  const key = url.searchParams.get("key");
  if (!key || !(managed ? isManagedKey(key) : isSafeObjectKey(key))) throw new HttpError(400, "A valid media object key is required.");
  return key;
}

async function publicMedia(request: Request, env: Env, encodedKey: string): Promise<Response> {
  let key: string;
  try {
    key = decodeURIComponent(encodedKey);
  } catch {
    throw new HttpError(400, "A valid media object key is required.");
  }
  if (!isManagedKey(key) || !(key.startsWith("products/public/") || key.startsWith("stores/public/"))) {
    throw new HttpError(404, "Media was not found.");
  }
  const object = await env.MEDIA_BUCKET.get(key);
  if (!object) throw new HttpError(404, "Media was not found.");
  if (key.startsWith("stores/public/") && object.customMetadata?.publicApproved !== "true") {
    throw new HttpError(404, "Media was not found.");
  }
  return objectResponse(object, CACHE_CONTROL_PUBLIC, request);
}

async function privateMedia(request: Request, env: Env, url: URL): Promise<Response> {
  const uid = await authenticateUser(request, env);
  const key = queryKey(url);
  const capability = await authorize(request, env, "media:read");
  if (capability.sub !== uid || capability.objectKey !== key) {
    throw new HttpError(403, "This account cannot access the requested media.");
  }
  const object = await env.MEDIA_BUCKET.get(key);
  if (!object) throw new HttpError(404, "Media was not found.");
  return objectResponse(object, CACHE_CONTROL_PRIVATE, request);
}

async function publishedPanoramaMedia(request: Request, env: Env, url: URL): Promise<Response> {
  const key = queryKey(url);
  const capability = await authorize(request, env, "media:public-read");
  const match = /^tours\/derivatives\/([A-Za-z0-9_-]{1,128})\/([1-9][0-9]{0,15})\/([1-9][0-9]{0,15})\/([A-Za-z0-9_-]{16,64})_([a-f0-9]{64})\.jpg$/.exec(key);
  if (!match || capability.objectKey !== key || Number(capability.tourId) !== Number(match[2]) ||
      Number(capability.nodeId) !== Number(match[3]) || capability.derivativeSha256 !== match[5]) {
    throw new HttpError(403, "This publication authorization does not match the requested panorama.");
  }
  const object = await env.MEDIA_BUCKET.get(key);
  if (!object || object.httpMetadata?.contentType !== "image/jpeg" ||
      object.customMetadata?.publicApproved !== "true" || object.customMetadata?.sha256 !== match[5]) {
    throw new HttpError(404, "Media was not found.");
  }
  return objectResponse(object, CACHE_CONTROL_PRIVATE, request);
}

function internalKey(payload: JWTPayload, url: URL, scope: string): string {
  const key = queryKey(url, scope === "object:put");
  if (payload.objectKey !== key) throw new HttpError(403, "The gateway authorization does not match this object.");
  if (scope === "object:put" && payload.maxBytes !== undefined &&
      (!Number.isSafeInteger(payload.maxBytes) || Number(payload.maxBytes) < 1 || Number(payload.maxBytes) > PANORAMA_MAX_BYTES)) {
    throw new HttpError(401, "The gateway authorization is invalid.");
  }
  return key;
}

async function internalObject(request: Request, env: Env, url: URL): Promise<Response> {
  const scope = request.method === "GET" ? "object:get" :
    request.method === "HEAD" ? "object:head" :
      request.method === "PUT" ? "object:put" :
        request.method === "DELETE" ? "object:delete" : "";
  if (!scope) return json({ error: "Method not allowed." }, 405, { Allow: "GET, HEAD, PUT, DELETE", ...NO_CACHE_HEADERS });
  const capability = await authorize(request, env, scope);
  const key = internalKey(capability, url, scope);

  if (request.method === "DELETE") {
    const previous = await env.MEDIA_BUCKET.head(key);
    await env.MEDIA_BUCKET.delete(key);
    if (await env.MEDIA_BUCKET.head(key)) throw new HttpError(503, "The object deletion could not be verified.");
    return json({ deleted: true, existed: previous != null, key }, 200, NO_CACHE_HEADERS);
  }
  if (request.method === "PUT") {
    const limit = Number(capability.maxBytes);
    const type = request.headers.get("Content-Type")?.split(";", 1)[0].trim().toLowerCase();
    const length = Number(request.headers.get("Content-Length"));
    if (!Number.isSafeInteger(limit) || limit < 1 || !IMAGE_TYPES.has(type ?? "") ||
        !Number.isSafeInteger(length) || length < 1 || length > limit || !request.body) {
      throw new HttpError(413, "The internal object size or type is invalid.");
    }
    let stored: R2Object | null;
    try {
      stored = await env.MEDIA_BUCKET.put(key, checkedUploadStream(request.body, length, limit, type!), {
        onlyIf: { etagDoesNotMatch: "*" },
        httpMetadata: { contentType: type!, cacheControl: key.startsWith("products/public/") || key.startsWith("stores/public/") ? CACHE_CONTROL_PUBLIC : CACHE_CONTROL_PRIVATE },
        customMetadata: {
          state: "processed",
          ...(typeof capability.reservationId === "string" ? { reservationId: capability.reservationId } : {}),
          ...(typeof capability.uid === "string" ? { uid: capability.uid } : {}),
          ...(typeof capability.mediaType === "string" ? { mediaType: capability.mediaType } : {}),
          ...(capability.publicApproved === false ? { publicApproved: "false" } : {}),
        },
      });
    } catch {
      throw new HttpError(400, "The internal object body could not be stored.");
    }
    if (!stored) throw new HttpError(409, "The target object already exists.");
    if (stored.size !== length || stored.size > limit) {
      await env.MEDIA_BUCKET.delete(key);
      if (await env.MEDIA_BUCKET.head(key)) throw new HttpError(503, "An invalid object could not be cleaned up.");
      throw new HttpError(413, "The actual object size exceeded its authorization.");
    }
    return json({ key, size: stored.size, etag: stored.etag }, 201, NO_CACHE_HEADERS);
  }

  if (request.method === "HEAD") {
    const object = await env.MEDIA_BUCKET.head(key);
    if (!object) return new Response(null, { status: 404, headers: NO_CACHE_HEADERS });
    const headers = new Headers({
      ...NO_CACHE_HEADERS,
      "Content-Length": String(object.size),
      "Content-Type": object.httpMetadata?.contentType ?? "application/octet-stream",
      ETag: object.httpEtag,
      "Last-Modified": object.uploaded.toUTCString(),
    });
    for (const [name, value] of Object.entries(object.customMetadata ?? {})) {
      if (["reservationId", "uid", "mediaType", "sha256", "publicApproved"].includes(name)) headers.set(`X-Object-${name.replace(/[A-Z]/g, (letter) => `-${letter}`).toLowerCase()}`, value);
    }
    return new Response(null, { status: 200, headers });
  }
  const object = await env.MEDIA_BUCKET.get(key);
  if (!object) return json({ error: "Object was not found." }, 404, NO_CACHE_HEADERS);
  return objectResponse(object, CACHE_CONTROL_PRIVATE, request);
}

async function publishMedia(request: Request, env: Env, url: URL): Promise<Response> {
  if (request.method !== "POST") return json({ error: "Method not allowed." }, 405, { Allow: "POST", ...NO_CACHE_HEADERS });
  const capability = await authorize(request, env, "object:publish");
  const key = queryKey(url, false);
  const panorama = /^tours\/derivatives\/([A-Za-z0-9_-]{1,128})\/([1-9][0-9]{0,15})\/([1-9][0-9]{0,15})\/([A-Za-z0-9_-]{16,64})_([a-f0-9]{64})\.jpg$/.exec(key);
  const storeImage = key.startsWith("stores/public/");
  if (capability.objectKey !== key || (!storeImage && !panorama)) throw new HttpError(403, "This authorization cannot publish the requested object.");
  if (panorama && (Number(capability.tourId) !== Number(panorama[2]) ||
      Number(capability.nodeId) !== Number(panorama[3]) || capability.derivativeSha256 !== panorama[5])) {
    throw new HttpError(403, "This authorization cannot publish the requested panorama.");
  }
  const current = await env.MEDIA_BUCKET.get(key);
  if (!current) throw new HttpError(404, "The store image was not found.");
  if (panorama && (current.httpMetadata?.contentType !== "image/jpeg" || current.customMetadata?.sha256 !== panorama[5])) {
    throw new HttpError(409, "The panorama derivative does not match its publication authorization.");
  }
  if (current.customMetadata?.publicApproved === "true") {
    return json({ published: true, key, size: current.size, ...(panorama ? { sha256: panorama[5] } : {}) }, 200, NO_CACHE_HEADERS);
  }
  const updated = await env.MEDIA_BUCKET.put(key, current.body, {
    onlyIf: { etagMatches: current.etag },
    httpMetadata: current.httpMetadata,
    customMetadata: { ...(current.customMetadata ?? {}), publicApproved: "true" },
  });
  if (!updated) throw new HttpError(409, "The store image changed before it could be published.");
  const verified = await env.MEDIA_BUCKET.head(key);
  if (!verified || verified.size !== current.size || verified.customMetadata?.publicApproved !== "true" ||
      (panorama && verified.customMetadata?.sha256 !== panorama[5])) {
    throw new HttpError(503, "Store image publication could not be verified.");
  }
  return json({ published: true, key, size: verified.size, ...(panorama ? { sha256: panorama[5] } : {}) }, 200, NO_CACHE_HEADERS);
}

async function listObjects(request: Request, env: Env, url: URL): Promise<Response> {
  if (request.method !== "GET") return json({ error: "Method not allowed." }, 405, { Allow: "GET", ...NO_CACHE_HEADERS });
  await authorize(request, env, "objects:list");
  const rawLimit = Number(url.searchParams.get("limit") ?? "1000");
  if (!Number.isSafeInteger(rawLimit) || rawLimit < 1 || rawLimit > 1000) throw new HttpError(400, "Page size must be from 1 to 1000.");
  const cursor = url.searchParams.get("cursor") ?? undefined;
  const page = await env.MEDIA_BUCKET.list({
    limit: rawLimit,
    include: ["customMetadata", "httpMetadata"],
    ...(cursor ? { cursor } : {}),
  });
  return json({
    objects: page.objects.map((object) => ({
      key: object.key,
      size: object.size,
      etag: object.etag,
      uploadedAt: object.uploaded.toISOString(),
      customMetadata: object.customMetadata ?? {},
    })),
    truncated: page.truncated,
    cursor: page.truncated ? page.cursor : null,
  }, 200, NO_CACHE_HEADERS);
}

async function handle(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);
  if (url.pathname === "/healthz" && request.method === "GET") return json({ ok: true });

  const uploadMatch = /^\/v1\/uploads\/([A-Za-z0-9_-]{16,128})$/.exec(url.pathname);
  if (uploadMatch && request.method === "PUT") return upload(request, env, uploadMatch[1]);

  const publicPrefix = "/v1/media/public/";
  if ((request.method === "GET" || request.method === "HEAD") && url.pathname.startsWith(publicPrefix)) {
    return publicMedia(request, env, url.pathname.slice(publicPrefix.length));
  }
  if ((request.method === "GET" || request.method === "HEAD") && url.pathname === "/v1/media/private") {
    return privateMedia(request, env, url);
  }
  if ((request.method === "GET" || request.method === "HEAD") && url.pathname === "/v1/media/panorama") {
    return publishedPanoramaMedia(request, env, url);
  }
  if (url.pathname === "/v1/internal/objects") return listObjects(request, env, url);
  if (url.pathname === "/v1/internal/object") return internalObject(request, env, url);
  if (url.pathname === "/v1/internal/publish") return publishMedia(request, env, url);
  return json({ error: "Route not found." }, 404, NO_CACHE_HEADERS);
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    try {
      return await handle(request, env);
    } catch (error) {
      return errorResponse(error);
    }
  },
};

export const __test__ = { isManagedKey, uploadObjectKey, checkedUploadStream };
