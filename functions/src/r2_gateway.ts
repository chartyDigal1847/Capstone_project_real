import { randomUUID, createPrivateKey, sign as signBytes } from "node:crypto";
import { defineSecret, defineString } from "firebase-functions/params";
import { HttpsError } from "firebase-functions/v2/https";

export const R2_GATEWAY_PRIVATE_JWK = defineSecret("R2_GATEWAY_PRIVATE_JWK");
export const R2_GATEWAY_URL = defineString("R2_GATEWAY_URL");

const TOKEN_LIFETIME_SECONDS = 5 * 60;
const TOKEN_ISSUER = "localspot-functions";
const TOKEN_AUDIENCE = "locentra-upload-gateway";

export interface R2ObjectMetadata {
  key: string;
  size: number;
  contentType: string;
  etag: string | null;
  reservationId: string | null;
  uid: string | null;
  mediaType: string | null;
  sha256: string | null;
  publicApproved: string | null;
}

export interface R2ListEntry {
  key: string;
  size: number;
  etag: string;
  uploadedAt: string;
  customMetadata: Record<string, string>;
}

function gatewayBaseUrl(): string {
  const value = R2_GATEWAY_URL.value().trim().replace(/\/+$/, "");
  // `demo-*` Firebase project IDs are emulator-only and cannot target a live
  // Firebase project. Restrict insecure HTTP to loopback and this exact E2E ID.
  const localEmulator = process.env.GCLOUD_PROJECT === "demo-localspot";
  if (localEmulator && /^http:\/\/(?:127\.0\.0\.1|localhost)(?::[0-9]{1,5})?$/.test(value)) return value;
  if (!/^https:\/\/[^/]+$/.test(value)) {
    throw new HttpsError("failed-precondition", "R2 gateway URL is not configured.");
  }
  return value;
}

function base64url(value: Buffer | string): string {
  return Buffer.from(value).toString("base64url");
}

export function signGatewayToken(
  claims: Record<string, unknown>,
  subject = "localspot-functions",
  tokenId = randomUUID(),
): string {
  let privateJwk: JsonWebKey & { kid?: string; d?: string };
  try {
    privateJwk = JSON.parse(R2_GATEWAY_PRIVATE_JWK.value()) as JsonWebKey & { kid?: string; d?: string };
  } catch {
    throw new HttpsError("failed-precondition", "R2 gateway signing key is not configured.");
  }
  if (privateJwk.kty !== "EC" || privateJwk.crv !== "P-256" || typeof privateJwk.d !== "string" || !privateJwk.kid) {
    throw new HttpsError("failed-precondition", "R2 gateway signing key is invalid.");
  }
  const now = Math.floor(Date.now() / 1000);
  const header = { alg: "ES256", typ: "JWT", kid: privateJwk.kid };
  const payload = {
    iss: TOKEN_ISSUER,
    aud: TOKEN_AUDIENCE,
    sub: subject,
    iat: now,
    exp: now + TOKEN_LIFETIME_SECONDS,
    jti: tokenId,
    ...claims,
  };
  const signingInput = `${base64url(JSON.stringify(header))}.${base64url(JSON.stringify(payload))}`;
  const key = createPrivateKey({ key: privateJwk, format: "jwk" });
  const signature = signBytes("sha256", Buffer.from(signingInput), { key, dsaEncoding: "ieee-p1363" });
  return `${signingInput}.${base64url(signature)}`;
}

export function r2UploadUrl(reservationId: string): string {
  return `${gatewayBaseUrl()}/v1/uploads/${encodeURIComponent(reservationId)}`;
}

export function r2PublicMediaUrl(key: string): string {
  return `${gatewayBaseUrl()}/v1/media/public/${encodeURIComponent(key)}`;
}

export function r2PrivateMediaUrl(key: string): string {
  return `${gatewayBaseUrl()}/v1/media/private?key=${encodeURIComponent(key)}`;
}

export function r2PublishedPanoramaUrl(key: string): string {
  return `${gatewayBaseUrl()}/v1/media/panorama?key=${encodeURIComponent(key)}`;
}

function backendAuthorization(scope: string, objectKey?: string, additional: Record<string, unknown> = {}): string {
  return signGatewayToken({ scope, ...(objectKey ? { objectKey } : {}), ...additional });
}

async function gatewayRequest(
  path: string,
  method: "GET" | "HEAD" | "PUT" | "DELETE" | "POST",
  scope: string,
  options: {
    key?: string;
    maxBytes?: number;
    contentType?: string;
    body?: Buffer;
    query?: Record<string, string>;
    metadata?: Record<string, unknown>;
  } = {},
): Promise<Response> {
  const url = new URL(`${gatewayBaseUrl()}${path}`);
  for (const [name, value] of Object.entries(options.query ?? {})) url.searchParams.set(name, value);
  const token = backendAuthorization(scope, options.key, {
    ...(options.maxBytes == null ? {} : { maxBytes: options.maxBytes }),
    ...(options.metadata ?? {}),
  });
  const body = options.body ? Uint8Array.from(options.body) : undefined;
  let response: Response;
  try {
    response = await fetch(url, {
      method,
      headers: {
        "X-Gateway-Authorization": `Bearer ${token}`,
        ...(options.contentType ? { "Content-Type": options.contentType } : {}),
        ...(body ? { "Content-Length": String(body.byteLength) } : {}),
      },
      ...(body ? { body } : {}),
    });
  } catch {
    throw new HttpsError("unavailable", "The R2 storage gateway could not be reached.");
  }
  if (!response.ok && !(method === "HEAD" && response.status === 404)) {
    throw new HttpsError("unavailable", `R2 storage operation failed (${response.status}).`);
  }
  return response;
}

export async function r2Head(key: string): Promise<R2ObjectMetadata | null> {
  const response = await gatewayRequest("/v1/internal/object", "HEAD", "object:head", { key, query: { key } });
  if (response.status === 404) return null;
  const size = Number(response.headers.get("Content-Length"));
  if (!Number.isSafeInteger(size) || size < 0) throw new HttpsError("data-loss", "R2 returned invalid object metadata.");
  return {
    key,
    size,
    contentType: response.headers.get("Content-Type") ?? "application/octet-stream",
    etag: response.headers.get("ETag"),
    reservationId: response.headers.get("X-Object-Reservation-Id"),
    uid: response.headers.get("X-Object-Uid"),
    mediaType: response.headers.get("X-Object-Media-Type"),
    sha256: response.headers.get("X-Object-Sha256"),
    publicApproved: response.headers.get("X-Object-Public-Approved"),
  };
}

export async function r2Read(key: string): Promise<Buffer> {
  const response = await gatewayRequest("/v1/internal/object", "GET", "object:get", { key, query: { key } });
  return Buffer.from(await response.arrayBuffer());
}

export async function r2Put(
  key: string,
  bytes: Buffer,
  contentType: string,
  maxBytes = bytes.length,
  metadata: { reservationId?: string; uid?: string; mediaType?: string; publicApproved?: boolean } = {},
): Promise<void> {
  await gatewayRequest("/v1/internal/object", "PUT", "object:put", {
    key,
    maxBytes,
    contentType,
    body: bytes,
    query: { key },
    metadata,
  });
}

export async function r2Delete(key: string): Promise<{ existed: boolean }> {
  const response = await gatewayRequest("/v1/internal/object", "DELETE", "object:delete", { key, query: { key } });
  const result = await response.json() as { deleted?: unknown; existed?: unknown };
  if (result.deleted !== true || typeof result.existed !== "boolean") {
    throw new HttpsError("data-loss", "R2 did not confirm the object deletion.");
  }
  return { existed: result.existed };
}

export async function r2PublishStoreImage(key: string): Promise<void> {
  const response = await gatewayRequest("/v1/internal/publish", "POST", "object:publish", { key, query: { key } });
  const result = await response.json() as { published?: unknown; size?: unknown };
  if (result.published !== true || !Number.isSafeInteger(result.size)) {
    throw new HttpsError("data-loss", "R2 did not confirm store image publication.");
  }
}

export async function r2PublishPanoramaDerivative(input: {
  key: string;
  tourId: number;
  nodeId: number;
  sha256: string;
}): Promise<void> {
  const response = await gatewayRequest("/v1/internal/publish", "POST", "object:publish", {
    key: input.key,
    query: { key: input.key },
    metadata: { tourId: input.tourId, nodeId: input.nodeId, derivativeSha256: input.sha256 },
  });
  const result = await response.json() as { published?: unknown; key?: unknown; size?: unknown; sha256?: unknown };
  if (result.published !== true || result.key !== input.key || result.sha256 !== input.sha256 || !Number.isSafeInteger(result.size)) {
    throw new HttpsError("data-loss", "R2 did not confirm panorama derivative publication.");
  }
}

export async function r2ListPage(cursor?: string, limit = 1000): Promise<{
  objects: R2ListEntry[];
  truncated: boolean;
  cursor: string | null;
}> {
  const response = await gatewayRequest("/v1/internal/objects", "GET", "objects:list", {
    query: { limit: String(limit), ...(cursor ? { cursor } : {}) },
  });
  const page = await response.json() as {
    objects?: R2ListEntry[];
    truncated?: boolean;
    cursor?: string | null;
  };
  if (!Array.isArray(page.objects) || typeof page.truncated !== "boolean") {
    throw new HttpsError("data-loss", "R2 returned an invalid object listing.");
  }
  return { objects: page.objects, truncated: page.truncated, cursor: page.cursor ?? null };
}
