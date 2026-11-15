import { beforeAll, afterAll, describe, expect, it, vi } from "vitest";
import { exportJWK, generateKeyPair, importPKCS8, SignJWT, type JWK } from "jose";
import * as selfsigned from "selfsigned";
import worker from "../src/index.js";

const PROJECT_ID = "capstone-project-561a2";
const UID = "user_123";
const ASSET_ID = "asset_12345678";
const RESERVATION_ID = "reservation_123456789";
const IMAGE_KEY = `products/quarantine/${UID}/${ASSET_ID}`;
const PNG = new Uint8Array([137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 0]);
const JPEG = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x02, 0x11, 0x22, 0xff, 0xd9]);
const DERIVATIVE_SHA256 = "b".repeat(64);
const DERIVATIVE_KEY = `tours/derivatives/${UID}/91/3/abcdef0123456789_${DERIVATIVE_SHA256}.jpg`;

class TestFixedLengthStream extends TransformStream<Uint8Array, Uint8Array> {
  constructor(expected: number) {
    let received = 0;
    super({
      transform(chunk, controller) {
        received += chunk.byteLength;
        if (received > expected) throw new Error("stream longer than declared length");
        controller.enqueue(chunk);
      },
      flush() {
        if (received !== expected) throw new Error("stream shorter than declared length");
      },
    });
  }
}

Object.assign(globalThis, { FixedLengthStream: TestFixedLengthStream });

let firebaseCertificate: string;
let firebasePrivateKey: CryptoKey;
let gatewayPrivateKey: CryptoKey;
let gatewayJwks: string;
let originalFetch: typeof fetch;

function makeObject(key: string, bytes: Uint8Array, contentType = "image/png", customMetadata: Record<string, string> = {}): R2ObjectBody {
  const body = new Response(bytes).body!;
  return {
    key,
    version: "version-1",
    size: bytes.byteLength,
    etag: "etag-1",
    httpEtag: '"etag-1"',
    uploaded: new Date("2026-11-15T00:00:00.000Z"),
    httpMetadata: { contentType },
    customMetadata,
    checksums: { toJSON: () => ({}) },
    storageClass: "Standard",
    body,
    bodyUsed: false,
    arrayBuffer: () => Promise.resolve(bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength)),
    text: () => Promise.resolve(new TextDecoder().decode(bytes)),
    json: () => Promise.resolve(JSON.parse(new TextDecoder().decode(bytes))),
    blob: () => Promise.resolve(new Blob([bytes], { type: contentType })),
    writeHttpMetadata: (headers: Headers) => headers.set("Content-Type", contentType),
  } as unknown as R2ObjectBody;
}

function mockBucket() {
  const files = new Map<string, { bytes: Uint8Array; contentType: string; etag: string; customMetadata: Record<string, string> }>();
  const bucket = {
    async put(key: string, body: ReadableStream<Uint8Array> | ArrayBuffer | string, options?: R2PutOptions) {
      if (options?.onlyIf?.etagDoesNotMatch === "*" && files.has(key)) return null;
      if (options?.onlyIf?.etagMatches && files.get(key)?.etag !== options.onlyIf.etagMatches) return null;
      const bytes = new Uint8Array(await new Response(body as BodyInit).arrayBuffer());
      const contentType = options?.httpMetadata?.contentType ?? "application/octet-stream";
      const entry = { bytes, contentType, etag: `etag-${files.size + 1}`, customMetadata: options?.customMetadata ?? {} };
      files.set(key, entry);
      return { key, size: bytes.length, etag: entry.etag } as R2Object;
    },
    async get(key: string) {
      const entry = files.get(key);
      return entry ? makeObject(key, entry.bytes, entry.contentType, entry.customMetadata) : null;
    },
    async head(key: string) {
      const entry = files.get(key);
      return entry ? { key, size: entry.bytes.length, etag: entry.etag, httpEtag: `"${entry.etag}"`, uploaded: new Date(), httpMetadata: { contentType: entry.contentType }, customMetadata: entry.customMetadata } as R2Object : null;
    },
    async delete(key: string) { files.delete(key); },
    async list(options?: R2ListOptions) {
      const keys = [...files.keys()].sort();
      const start = options?.cursor ? Number(options.cursor) : 0;
      const limit = options?.limit ?? 1000;
      const selected = keys.slice(start, start + limit);
      return {
        objects: selected.map((key) => {
          const item = files.get(key)!;
          return { key, size: item.bytes.length, etag: item.etag, uploaded: new Date(), customMetadata: {} };
        }),
        truncated: start + limit < keys.length,
        cursor: start + limit < keys.length ? String(start + limit) : undefined,
      } as R2Objects;
    },
    files,
  };
  return bucket;
}

async function firebaseToken(): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  return new SignJWT({ auth_time: now })
    .setProtectedHeader({ alg: "RS256", kid: "firebase-test-kid" })
    .setIssuer(`https://securetoken.google.com/${PROJECT_ID}`)
    .setAudience(PROJECT_ID)
    .setSubject(UID)
    .setIssuedAt(now)
    .setExpirationTime(now + 3600)
    .sign(firebasePrivateKey);
}

async function gatewayToken(claims: Record<string, unknown>): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  return new SignJWT(claims)
    .setProtectedHeader({ alg: "ES256", kid: "gateway-test-kid" })
    .setIssuer("localspot-functions")
    .setAudience("locentra-upload-gateway")
    .setSubject(UID)
    .setIssuedAt(now)
    .setExpirationTime(now + 120)
    .setJti(RESERVATION_ID)
    .sign(gatewayPrivateKey);
}

async function uploadRequest(overrides: {
  bytes?: Uint8Array;
  contentLength?: number;
  contentType?: string;
  claims?: Record<string, unknown>;
} = {}): Promise<Request> {
  const bytes = overrides.bytes ?? PNG;
  const token = await firebaseToken();
  const capability = await gatewayToken({
    scope: "upload",
    objectKey: IMAGE_KEY,
    contentType: "image/png",
    maxBytes: 1024,
    mediaType: "product",
    assetId: ASSET_ID,
    ...overrides.claims,
  });
  return new Request(`https://gateway.test/v1/uploads/${RESERVATION_ID}`, {
    method: "PUT",
    headers: {
      Authorization: `Bearer ${token}`,
      "X-Upload-Authorization": `Bearer ${capability}`,
      "Content-Type": overrides.contentType ?? "image/png",
      "Content-Length": String(overrides.contentLength ?? bytes.length),
    },
    body: bytes,
  });
}

async function derivativeUploadRequest(overrides: {
  contentType?: string;
  claims?: Record<string, unknown>;
} = {}): Promise<Request> {
  const token = await firebaseToken();
  const capability = await gatewayToken({
    scope: "upload",
    objectKey: DERIVATIVE_KEY,
    contentType: "image/jpeg",
    maxBytes: 50 * 1024 * 1024,
    mediaType: "panorama-derivative",
    assetId: ASSET_ID,
    tourId: 91,
    nodeId: 3,
    revisionId: "abcdef0123456789",
    derivativeSha256: DERIVATIVE_SHA256,
    ...overrides.claims,
  });
  return new Request(`https://gateway.test/v1/uploads/${RESERVATION_ID}`, {
    method: "PUT",
    headers: {
      Authorization: `Bearer ${token}`,
      "X-Upload-Authorization": `Bearer ${capability}`,
      "Content-Type": overrides.contentType ?? "image/jpeg",
      "Content-Length": String(JPEG.length),
    },
    body: JPEG,
  });
}

describe("R2 upload gateway", () => {
  beforeAll(async () => {
    const certificate = await selfsigned.generate([{ name: "commonName", value: "firebase-test" }], { keySize: 2048, algorithm: "sha256" });
    firebaseCertificate = certificate.cert;
    firebasePrivateKey = await importPKCS8(certificate.private, "RS256");

    const pair = await generateKeyPair("ES256");
    gatewayPrivateKey = pair.privateKey;
    const publicJwk = await exportJWK(pair.publicKey) as JWK;
    publicJwk.kid = "gateway-test-kid";
    publicJwk.alg = "ES256";
    publicJwk.use = "sig";
    publicJwk.key_ops = ["verify"];
    gatewayJwks = JSON.stringify({ keys: [publicJwk] });

    originalFetch = globalThis.fetch;
    globalThis.fetch = vi.fn(async () => new Response(
      JSON.stringify({ "firebase-test-kid": firebaseCertificate }),
      { headers: { "Content-Type": "application/json", "Cache-Control": "public,max-age=3600" } },
    ));
  });

  afterAll(() => { globalThis.fetch = originalFetch; });

  function env() {
    return {
      MEDIA_BUCKET: mockBucket(),
      FIREBASE_PROJECT_ID: PROJECT_ID,
      GATEWAY_PUBLIC_JWKS: gatewayJwks,
    } as unknown as Env;
  }

  it("rejects a request without Firebase authentication", async () => {
    const response = await worker.fetch(new Request("https://gateway.test/v1/uploads/" + RESERVATION_ID, { method: "PUT" }), env());
    expect(response.status).toBe(401);
  });

  it("stores a valid, signature-checked upload at the server-derived key", async () => {
    const runtime = env();
    const response = await worker.fetch(await uploadRequest(), runtime);
    expect(response.status).toBe(201);
    expect(await response.json()).toMatchObject({ uploaded: true, reservationId: RESERVATION_ID, bytes: PNG.length });
    expect((runtime.MEDIA_BUCKET as unknown as ReturnType<typeof mockBucket>).files.has(IMAGE_KEY)).toBe(true);
  });

  it("stores panorama derivatives only at immutable digest-scoped JPEG keys", async () => {
    const runtime = env();
    const response = await worker.fetch(await derivativeUploadRequest(), runtime);
    expect(response.status).toBe(201);
    expect((await response.json()).bytes).toBe(JPEG.length);
    const bucket = runtime.MEDIA_BUCKET as unknown as ReturnType<typeof mockBucket>;
    expect(bucket.files.get(DERIVATIVE_KEY)?.customMetadata).toMatchObject({
      reservationId: RESERVATION_ID,
      uid: UID,
      mediaType: "panorama-derivative",
    });
    expect((await worker.fetch(await derivativeUploadRequest(), runtime)).status).toBe(409);
  });

  it("rejects non-JPEG panorama derivatives", async () => {
    const response = await worker.fetch(await derivativeUploadRequest({ contentType: "image/png" }), env());
    expect(response.status).toBe(415);
  });

  it("rejects a client body that does not match its reported size", async () => {
    const runtime = env();
    const response = await worker.fetch(await uploadRequest({ bytes: new Uint8Array([...PNG, ...new Uint8Array(8)]), contentLength: PNG.length }), runtime);
    expect(response.status).toBe(400);
    expect((runtime.MEDIA_BUCKET as unknown as ReturnType<typeof mockBucket>).files.size).toBe(0);
  });

  it("rejects an invalid image signature before storing the object", async () => {
    const runtime = env();
    const response = await worker.fetch(await uploadRequest({ bytes: new Uint8Array(12).fill(1) }), runtime);
    expect(response.status).toBe(415);
    expect((runtime.MEDIA_BUCKET as unknown as ReturnType<typeof mockBucket>).files.size).toBe(0);
  });

  it("rejects an upload whose HTTP body exceeds its declared length", async () => {
    const runtime = env();
    const response = await worker.fetch(await uploadRequest({ bytes: new Uint8Array([...PNG, 1, 2, 3]), contentLength: PNG.length }), runtime);
    expect(response.status).toBe(400);
    expect((runtime.MEDIA_BUCKET as unknown as ReturnType<typeof mockBucket>).files.size).toBe(0);
  });

  it("rejects reservations larger than the per-media limit", async () => {
    const response = await worker.fetch(await uploadRequest({ claims: { maxBytes: 1024 * 1024 * 9 } }), env());
    expect(response.status).toBe(401);
  });

  it("rejects an actual body larger than the reserved byte maximum", async () => {
    const response = await worker.fetch(await uploadRequest({
      bytes: new Uint8Array([...PNG, ...new Uint8Array(8)]),
      contentLength: 20,
      claims: { maxBytes: PNG.length },
    }), env());
    expect(response.status).toBe(413);
  });

  it("rejects a second use of an upload reservation", async () => {
    const runtime = env();
    expect((await worker.fetch(await uploadRequest(), runtime)).status).toBe(201);
    expect((await worker.fetch(await uploadRequest(), runtime)).status).toBe(409);
  });

  it("serves only public object prefixes with public caching", async () => {
    const runtime = env();
    const key = `products/public/${UID}/${ASSET_ID}.png`;
    await runtime.MEDIA_BUCKET.put(key, PNG, { httpMetadata: { contentType: "image/png" } });
    const response = await worker.fetch(new Request(`https://gateway.test/v1/media/public/${encodeURIComponent(key)}`), runtime);
    expect(response.status).toBe(200);
    expect(response.headers.get("Cache-Control")).toBe("public,max-age=86400");
    const privateResponse = await worker.fetch(new Request(`https://gateway.test/v1/media/public/${encodeURIComponent(IMAGE_KEY)}`), runtime);
    expect(privateResponse.status).toBe(404);
  });

  it("keeps store images private until the signed publication step completes", async () => {
    const runtime = env();
    const bucket = runtime.MEDIA_BUCKET as unknown as ReturnType<typeof mockBucket>;
    const key = "stores/public/42/asset_12345678.jpg";
    bucket.files.set(key, { bytes: PNG, contentType: "image/png", etag: "etag-1", customMetadata: { publicApproved: "false" } });
    const pending = await worker.fetch(new Request(`https://gateway.test/v1/media/public/${encodeURIComponent(key)}`), runtime);
    expect(pending.status).toBe(404);

    const capability = await gatewayToken({ scope: "object:publish", objectKey: key });
    const published = await worker.fetch(new Request(`https://gateway.test/v1/internal/publish?key=${encodeURIComponent(key)}`, {
      method: "POST", headers: { "X-Gateway-Authorization": `Bearer ${capability}` },
    }), runtime);
    expect(published.status).toBe(200);
    expect((await published.json()).published).toBe(true);
    const visible = await worker.fetch(new Request(`https://gateway.test/v1/media/public/${encodeURIComponent(key)}`), runtime);
    expect(visible.status).toBe(200);
    expect(visible.headers.get("Cache-Control")).toContain("public");
  });

  it("delivers panorama derivatives only with a digest-bound publication capability", async () => {
    const runtime = env();
    const bucket = runtime.MEDIA_BUCKET as unknown as ReturnType<typeof mockBucket>;
    const customMetadata = {
      reservationId: RESERVATION_ID,
      uid: UID,
      mediaType: "panorama-derivative",
      sha256: DERIVATIVE_SHA256,
      publicApproved: "false",
    };
    bucket.files.set(DERIVATIVE_KEY, { bytes: JPEG, contentType: "image/jpeg", etag: "etag-1", customMetadata });

    const directPublic = await worker.fetch(new Request(`https://gateway.test/v1/media/public/${encodeURIComponent(DERIVATIVE_KEY)}`), runtime);
    expect(directPublic.status).toBe(404);
    const denied = await worker.fetch(new Request(`https://gateway.test/v1/media/panorama?key=${encodeURIComponent(DERIVATIVE_KEY)}`), runtime);
    expect(denied.status).toBe(401);

    const publicationCapability = await gatewayToken({
      scope: "object:publish",
      objectKey: DERIVATIVE_KEY,
      tourId: 91,
      nodeId: 3,
      derivativeSha256: DERIVATIVE_SHA256,
    });
    const published = await worker.fetch(new Request(`https://gateway.test/v1/internal/publish?key=${encodeURIComponent(DERIVATIVE_KEY)}`, {
      method: "POST",
      headers: { "X-Gateway-Authorization": `Bearer ${publicationCapability}` },
    }), runtime);
    expect(published.status).toBe(200);
    expect(await published.json()).toMatchObject({ published: true, sha256: DERIVATIVE_SHA256 });

    const readCapability = await gatewayToken({
      scope: "media:public-read",
      objectKey: DERIVATIVE_KEY,
      tourId: 91,
      nodeId: 3,
      derivativeSha256: DERIVATIVE_SHA256,
    });
    const delivered = await worker.fetch(new Request(`https://gateway.test/v1/media/panorama?key=${encodeURIComponent(DERIVATIVE_KEY)}`, {
      headers: { "X-Gateway-Authorization": `Bearer ${readCapability}` },
    }), runtime);
    expect(delivered.status).toBe(200);
    expect(delivered.headers.get("Cache-Control")).toBe("private,no-store");
    expect(new Uint8Array(await delivered.arrayBuffer())).toEqual(JPEG);

    const wrongDigest = await gatewayToken({
      scope: "media:public-read",
      objectKey: DERIVATIVE_KEY,
      tourId: 91,
      nodeId: 3,
      derivativeSha256: "c".repeat(64),
    });
    const mismatched = await worker.fetch(new Request(`https://gateway.test/v1/media/panorama?key=${encodeURIComponent(DERIVATIVE_KEY)}`, {
      headers: { "X-Gateway-Authorization": `Bearer ${wrongDigest}` },
    }), runtime);
    expect(mismatched.status).toBe(403);
  });

  it("delivers private media only with identity and a matching scoped capability", async () => {
    const runtime = env();
    const privateKey = `stores/processed/${UID}/${ASSET_ID}.png`;
    await runtime.MEDIA_BUCKET.put(privateKey, PNG, { httpMetadata: { contentType: "image/png" } });
    const idToken = await firebaseToken();
    const noCapability = await worker.fetch(new Request(`https://gateway.test/v1/media/private?key=${encodeURIComponent(privateKey)}`, {
      headers: { Authorization: `Bearer ${idToken}` },
    }), runtime);
    expect(noCapability.status).toBe(401);
    const capability = await gatewayToken({ scope: "media:read", objectKey: privateKey });
    const delivered = await worker.fetch(new Request(`https://gateway.test/v1/media/private?key=${encodeURIComponent(privateKey)}`, {
      headers: { Authorization: `Bearer ${idToken}`, "X-Gateway-Authorization": `Bearer ${capability}` },
    }), runtime);
    expect(delivered.status).toBe(200);
    expect(delivered.headers.get("Cache-Control")).toBe("private,no-store");
    expect(new Uint8Array(await delivered.arrayBuffer())).toEqual(PNG);
  });

  it("requires a signed backend capability before listing bucket objects", async () => {
    const runtime = env();
    const denied = await worker.fetch(new Request("https://gateway.test/v1/internal/objects"), runtime);
    expect(denied.status).toBe(401);
    const capability = await gatewayToken({ scope: "objects:list" });
    const allowed = await worker.fetch(new Request("https://gateway.test/v1/internal/objects", {
      headers: { "X-Gateway-Authorization": `Bearer ${capability}` },
    }), runtime);
    expect(allowed.status).toBe(200);
    expect(await allowed.json()).toMatchObject({ objects: [], truncated: false, cursor: null });
  });

  it("deletes only the authorized object and confirms absence on retries", async () => {
    const runtime = env();
    const key = `products/quarantine/${UID}/${ASSET_ID}`;
    await runtime.MEDIA_BUCKET.put(key, PNG, { httpMetadata: { contentType: "image/png" } });
    const capability = await gatewayToken({ scope: "object:delete", objectKey: key });
    const request = () => new Request(`https://gateway.test/v1/internal/object?key=${encodeURIComponent(key)}`, {
      method: "DELETE",
      headers: { "X-Gateway-Authorization": `Bearer ${capability}` },
    });
    const first = await worker.fetch(request(), runtime);
    expect(first.status).toBe(200);
    expect(await first.json()).toMatchObject({ deleted: true, existed: true, key });
    const retry = await worker.fetch(request(), runtime);
    expect(retry.status).toBe(200);
    expect(await retry.json()).toMatchObject({ deleted: true, existed: false, key });
  });
});
