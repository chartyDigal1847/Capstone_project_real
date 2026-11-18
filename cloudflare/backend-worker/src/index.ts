import { createLocalJWKSet, importX509, jwtVerify, type JWTPayload } from "jose";
import { FirestoreRest, FirestoreRestError, type FirestoreWrite } from "./firestore.js";
import { ApiError } from "./errors.js";
import { handleSubmissions } from "./submissions.js";
import { handleVendorLocations } from "./vendor_locations.js";
import { handlePromotions } from "./promotions.js";
import { handleListings } from "./listings.js";
import { handleStores } from "./stores.js";
import { handleTours } from "./tours.js";
import { handleStorageAdmin, handleStorageAvailability } from "./storage_admin.js";
import { handleStorageOrphanDelete } from "./storage_orphans.js";
import { handleStorageReconciliation } from "./storage_reconciliation.js";
import { runExpiredMediaCleanup } from "./media_expiry_cleanup.js";
import { deleteUserAccount } from "./account_delete.js";
import { reserveMediaUpload } from "./media_reservations.js";
import { finalizeMediaUpload } from "./media_finalize.js";
import { getPrivateMediaAccess } from "./media_access.js";
import { deleteMediaAsset } from "./media_delete.js";
import { cleanupAbandonedMediaReservations } from "./media_cleanup.js";
import { reservePanoramaDerivativeUpload } from "./panorama_reservations.js";
import { finalizePanoramaDerivativeUpload } from "./panorama_finalize.js";
import { recordTourPanoramaReview } from "./panorama_review.js";
import { getPanoramaPrivateMediaAccess } from "./panorama_access.js";
import { publishStoreTour, getPublishedTourPanoramaAccess } from "./panorama_publication.js";
import { isPrivateEmulatorHost } from "./r2_gateway_client.js";

export { ApiError } from "./errors.js";

const FIREBASE_CERT_URL = "https://www.googleapis.com/robot/v1/metadata/x509/securetoken@system.gserviceaccount.com";
const APP_CHECK_JWKS_URL = "https://firebaseappcheck.googleapis.com/v1/jwks";
const FIREBASE_UID_PATTERN = /^[A-Za-z0-9_-]{1,128}$/;

export interface Env {
  MEDIA_BUCKET: R2Bucket;
  FIREBASE_PROJECT_ID: string;
  FIREBASE_PROJECT_NUMBER: string;
  FIREBASE_WEB_API_KEY?: string;
  FIREBASE_ANDROID_APP_ID?: string;
  FIREBASE_AUTH_EMULATOR_URL?: string;
  FIRESTORE_EMULATOR_URL?: string;
  LOCAL_EMULATORS?: string;
  FIREBASE_SERVICE_ACCOUNT_JSON?: string;
  R2_GATEWAY_PRIVATE_JWK?: string;
  R2_GATEWAY_URL?: string;
  R2_GATEWAY?: Fetcher;
}

export interface Principal {
  uid: string;
  authTime: number;
  appId: string;
  claims: JWTPayload;
}

type Cache<T> = { value: T; expiresAt: number };
let firebaseCertCache: Cache<Record<string, string>> | undefined;
let appCheckKeyCache: Cache<ReturnType<typeof createLocalJWKSet>> | undefined;

function errorResponse(error: unknown): Response {
  const status = error instanceof ApiError ? error.status : 500;
  const message = error instanceof ApiError ? error.message : "The request could not be completed.";
  if (!(error instanceof ApiError)) console.error("Backend request failed", { kind: error instanceof Error ? error.name : "unknown" });
  return Response.json({ error: message }, { status, headers: { "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff" } });
}

function bearer(request: Request, header: string): string {
  const value = request.headers.get(header);
  const match = value?.match(/^Bearer ([A-Za-z0-9._~-]+)$/);
  if (!match) throw new ApiError(401, `A valid ${header} bearer token is required.`);
  return match[1];
}

async function firebaseCerts(): Promise<Record<string, string>> {
  if (firebaseCertCache && firebaseCertCache.expiresAt > Date.now()) return firebaseCertCache.value;
  const response = await fetch(FIREBASE_CERT_URL);
  if (!response.ok) throw new ApiError(503, "Firebase token verification is temporarily unavailable.");
  const certs: unknown = await response.json();
  if (!certs || typeof certs !== "object" || Array.isArray(certs)) throw new ApiError(503, "Firebase token verification is temporarily unavailable.");
  const maxAge = Number(response.headers.get("Cache-Control")?.match(/max-age=(\d+)/i)?.[1] ?? 300);
  firebaseCertCache = { value: certs as Record<string, string>, expiresAt: Date.now() + Math.max(0, maxAge) * 1000 };
  return firebaseCertCache.value;
}

async function verifyFirebaseToken(token: string, projectId: string): Promise<{ uid: string; authTime: number; claims: JWTPayload }> {
  try {
    const header = JSON.parse(atob(token.split(".")[0].replace(/-/g, "+").replace(/_/g, "/"))) as { alg?: unknown; kid?: unknown };
    if (header.alg !== "RS256" || typeof header.kid !== "string") throw new Error("Invalid token header");
    const certificate = (await firebaseCerts())[header.kid];
    if (!certificate) throw new Error("Unknown signing key");
    const key = await importX509(certificate, "RS256");
    const { payload } = await jwtVerify(token, key, {
      algorithms: ["RS256"],
      audience: projectId,
      issuer: `https://securetoken.google.com/${projectId}`,
      requiredClaims: ["sub", "iat", "exp", "auth_time"],
    });
    const now = Math.floor(Date.now() / 1000);
    if (typeof payload.sub !== "string" || !FIREBASE_UID_PATTERN.test(payload.sub) ||
        typeof payload.iat !== "number" || payload.iat > now + 30 ||
        typeof payload.auth_time !== "number" || payload.auth_time > now + 30) throw new Error("Invalid Firebase claims");
    return { uid: payload.sub, authTime: payload.auth_time, claims: payload };
  } catch {
    throw new ApiError(401, "The Firebase ID token is invalid or expired.");
  }
}

export function validateFirebaseAccountRecord(uid: string, authTime: number, user: unknown): void {
  if (!user || typeof user !== "object" || Array.isArray(user)) {
    console.warn("Firebase account lookup returned no user record");
    throw new ApiError(503, "Firebase account status is unavailable.");
  }
  const record = user as { localId?: unknown; disabled?: unknown; validSince?: unknown };
  if (record.localId !== uid) throw new ApiError(401, "The Firebase account is unavailable.");
  // Firebase Auth omits this optional field for enabled accounts.
  if (record.disabled !== undefined && typeof record.disabled !== "boolean") {
    throw new ApiError(503, "Firebase account status is unavailable.");
  }
  if (record.disabled) throw new ApiError(401, "The Firebase account is disabled or unavailable.");
  if (!Number.isSafeInteger(authTime) || authTime < 0) throw new ApiError(401, "The Firebase ID token is invalid.");
  const validSince = typeof record.validSince === "string" || typeof record.validSince === "number"
    ? Number(record.validSince) : Number.NaN;
  if (!Number.isSafeInteger(validSince) || validSince < 0) {
    console.warn("Firebase account lookup omitted a valid revocation timestamp", {
      hasValidSince: Object.hasOwn(record, "validSince"),
      validSinceType: typeof record.validSince,
    });
    throw new ApiError(503, "Firebase account status is unavailable.");
  }
  if (authTime < validSince) throw new ApiError(401, "The Firebase ID token has been revoked. Sign in again.");
}

export async function verifyCurrentFirebaseAccount(token: string, uid: string, authTime: number, env: Env): Promise<void> {
  if (!env.FIREBASE_WEB_API_KEY) throw new ApiError(503, "Firebase account status verification is not configured.");
  const endpoint = new URL("/v1/accounts:lookup", "https://identitytoolkit.googleapis.com");
  endpoint.searchParams.set("key", env.FIREBASE_WEB_API_KEY);
  let response: Response;
  try {
    response = await fetch(endpoint, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ idToken: token }),
      signal: AbortSignal.timeout(5_000),
    });
  } catch {
    throw new ApiError(503, "Firebase account status verification is temporarily unavailable.");
  }
  if (!response.ok) {
    let message = "";
    try { message = String((await response.json() as { error?: { message?: string } }).error?.message ?? ""); }
    catch { /* use the HTTP status */ }
    if (/^(INVALID_ID_TOKEN|TOKEN_EXPIRED|USER_DISABLED|USER_NOT_FOUND)$/i.test(message)) {
      throw new ApiError(401, "The Firebase account is disabled or the ID token is no longer valid.");
    }
    throw new ApiError(503, "Firebase account status verification is temporarily unavailable.");
  }
  let body: { users?: unknown };
  try { body = await response.json() as { users?: unknown }; }
  catch { throw new ApiError(503, "Firebase account status is unavailable."); }
  const users = Array.isArray(body.users) ? body.users : [];
  if (!users[0]) throw new ApiError(401, "The Firebase account is disabled or unavailable.");
  validateFirebaseAccountRecord(uid, authTime, users[0]);
}

async function appCheckKeys(): Promise<ReturnType<typeof createLocalJWKSet>> {
  if (appCheckKeyCache && appCheckKeyCache.expiresAt > Date.now()) return appCheckKeyCache.value;
  const response = await fetch(APP_CHECK_JWKS_URL);
  if (!response.ok) throw new ApiError(503, "App Check verification is temporarily unavailable.");
  const jwks = await response.json() as Parameters<typeof createLocalJWKSet>[0];
  const keys = createLocalJWKSet(jwks);
  const maxAge = Number(response.headers.get("Cache-Control")?.match(/max-age=(\d+)/i)?.[1] ?? 21600);
  appCheckKeyCache = { value: keys, expiresAt: Date.now() + Math.min(Math.max(maxAge, 60), 21600) * 1000 };
  return keys;
}

export function assertExpectedFirebaseAndroidApp(expectedAppId: string | undefined, tokenAppId: unknown): void {
  if (!expectedAppId) throw new ApiError(503, "The Android App Check identity is not configured.");
  if (typeof tokenAppId !== "string" || tokenAppId !== expectedAppId) throw new ApiError(401, "The Firebase App Check token is invalid or expired.");
}

export async function verifyAppCheck(token: string, env: Env): Promise<string> {
  if (!env.FIREBASE_ANDROID_APP_ID) throw new ApiError(503, "The Android App Check identity is not configured.");
  try {
    const { payload, protectedHeader } = await jwtVerify(token, await appCheckKeys(), {
      algorithms: ["RS256"],
      issuer: `https://firebaseappcheck.googleapis.com/${env.FIREBASE_PROJECT_NUMBER}`,
      requiredClaims: ["sub", "iat", "exp", "aud"],
    });
    if (protectedHeader.typ !== "JWT" || typeof payload.sub !== "string") throw new Error("Invalid App Check subject");
    const audience = Array.isArray(payload.aud) ? payload.aud : [payload.aud];
    if (!audience.includes(`projects/${env.FIREBASE_PROJECT_NUMBER}`)) throw new Error("Invalid App Check audience");
    if (typeof payload.iat !== "number" || payload.iat > Math.floor(Date.now() / 1000) + 30) throw new Error("Invalid App Check issue time");
    assertExpectedFirebaseAndroidApp(env.FIREBASE_ANDROID_APP_ID, payload.sub);
    return payload.sub;
  } catch {
    throw new ApiError(401, "The Firebase App Check token is invalid or expired.");
  }
}

async function emulatorIdentityToken(token: string, env: Env): Promise<{ uid: string; authTime: number; claims: JWTPayload }> {
  if (env.FIREBASE_PROJECT_ID !== "demo-localspot" || !env.FIREBASE_AUTH_EMULATOR_URL) throw new ApiError(503, "Auth emulator configuration is invalid.");
  const endpoint = new URL("/identitytoolkit.googleapis.com/v1/accounts:lookup?key=emulator", env.FIREBASE_AUTH_EMULATOR_URL);
  let response: Response;
  try {
    response = await fetch(endpoint, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ idToken: token }),
      signal: AbortSignal.timeout(5_000),
    });
  } catch {
    throw new ApiError(503, "The Firebase Auth emulator is temporarily unavailable.");
  }
  if (!response.ok) throw new ApiError(401, "The Firebase emulator ID token is invalid or expired.");
  const result = await response.json() as {
    users?: Array<{
      localId?: string;
      lastLoginAt?: string;
      email?: string;
      displayName?: string;
    }>;
  };
  const user = result.users?.[0];
  if (!user?.localId || !FIREBASE_UID_PATTERN.test(user.localId)) throw new ApiError(401, "The Firebase emulator ID token is invalid or expired.");
  return {
    uid: user.localId,
    authTime: Math.floor(Date.now() / 1000),
    claims: {
      sub: user.localId,
      ...(typeof user.email === "string" ? { email: user.email } : {}),
      ...(typeof user.displayName === "string" ? { name: user.displayName } : {}),
    },
  };
}

export async function authenticate(request: Request, env: Env): Promise<Principal> {
  const token = bearer(request, "Authorization");
  const identity = env.LOCAL_EMULATORS === "true"
    ? await emulatorIdentityToken(token, env)
    : await verifyFirebaseToken(token, env.FIREBASE_PROJECT_ID);
  const appCheckToken = bearer(request, "X-Firebase-AppCheck");
  const appId = env.LOCAL_EMULATORS === "true" ? "local-emulator" : await verifyAppCheck(appCheckToken, env);
  if (env.LOCAL_EMULATORS !== "true") await verifyCurrentFirebaseAccount(token, identity.uid, identity.authTime, env);
  return { ...identity, appId };
}

function stringField(value: unknown): { stringValue: string } {
  return { stringValue: typeof value === "string" ? value : "" };
}

async function numericIdForUid(uid: string): Promise<number> {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(uid)));
  return new DataView(digest.buffer).getUint32(0, false) & 0x7fffffff;
}

async function bootstrapProfile(request: Request, env: Env, principal: Principal): Promise<Response> {
  if (request.method !== "POST") return Response.json({ error: "Method not allowed." }, { status: 405, headers: { Allow: "POST" } });
  let requestedName = "";
  let requestedRole: "customer" | "owner" | "staff" = "customer";
  try {
    const body: unknown = await request.json();
    if (body && typeof body === "object" && !Array.isArray(body)) {
      const name = (body as Record<string, unknown>).name;
      const role = (body as Record<string, unknown>).role;
      if (typeof name === "string") requestedName = name.trim();
      if (requestedName.length > 80) throw new ApiError(400, "Profile name must be 80 characters or fewer.");
      if (role !== undefined) {
        if (role !== "customer" && role !== "owner" && role !== "staff") throw new ApiError(400, "A valid account type is required.");
        requestedRole = role;
      }
    }
  } catch (error) {
    if (error instanceof ApiError) throw error;
    throw new ApiError(400, "The profile bootstrap request is invalid.");
  }
  const store = new FirestoreRest(env);
  const documentName = `projects/${env.FIREBASE_PROJECT_ID}/databases/(default)/documents/users/${principal.uid}`;
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      const current = await store.get(`users/${principal.uid}`);
      if (current) {
        return Response.json({ ok: true, created: false, uid: principal.uid, profile: current.fields ?? {} }, { headers: { "Cache-Control": "no-store" } });
      }
      const email = typeof principal.claims.email === "string" ? principal.claims.email : "";
      const tokenName = typeof principal.claims.name === "string" ? principal.claims.name.trim() : "";
      const displayName = requestedName || (tokenName
        ? tokenName.slice(0, 80)
        : email.split("@")[0]?.slice(0, 80) || "Customer");
      const write: FirestoreWrite = {
        update: {
          name: documentName,
          fields: {
            numericId: { integerValue: String(await numericIdForUid(principal.uid)) },
            name: stringField(displayName),
            email: stringField(email),
            role: stringField(requestedRole),
            ownedStoreIds: { arrayValue: { values: [] } },
            memberStoreIds: { arrayValue: { values: [] } },
            storeGrants: { arrayValue: { values: [] } },
          },
        },
        currentDocument: { exists: false },
      };
      await store.commit([write]);
      return Response.json({ ok: true, created: true, uid: principal.uid, role: "customer" }, { headers: { "Cache-Control": "no-store" } });
    } catch (error) {
      if (error instanceof FirestoreRestError && ["ALREADY_EXISTS", "ABORTED", "FAILED_PRECONDITION"].includes(error.code)) {
        const existing = await store.get(`users/${principal.uid}`);
        if (existing) return Response.json({ ok: true, created: false, uid: principal.uid, profile: existing.fields ?? {} }, { headers: { "Cache-Control": "no-store" } });
        if (attempt < 2) continue;
      }
      throw error;
    }
  }
  throw new ApiError(503, "Profile initialization could not be completed. Retry shortly.");
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    let requestPath = "";
    try {
      const url = new URL(request.url);
      requestPath = url.pathname;
      if (env.LOCAL_EMULATORS === "true" && !isPrivateEmulatorHost(url.hostname)) {
        return Response.json({ error: "This Worker is configured for local emulators only." }, { status: 503, headers: { "Cache-Control": "no-store" } });
      }
      if (url.pathname === "/healthz" && request.method === "GET") return Response.json({ ok: true });
      if (!url.pathname.startsWith("/api/v1/")) return Response.json({ error: "Route not found." }, { status: 404 });
      const principal = await authenticate(request, env);
      if (url.pathname === "/api/v1/auth/profile/bootstrap") return await bootstrapProfile(request, env, principal);
      if (url.pathname === "/api/v1/account/delete") return await deleteUserAccount(request, env, principal);
      if (["/api/v1/feedback", "/api/v1/reports", "/api/v1/admin/reports/resolve"].includes(url.pathname)) {
        return await handleSubmissions(request, env, principal, url.pathname);
      }
      if (url.pathname.startsWith("/api/v1/vendor-locations/")) {
        return await handleVendorLocations(request, env, principal, url.pathname);
      }
      if (url.pathname === "/api/v1/promotions" || url.pathname === "/api/v1/admin/promotions/review") {
        return await handlePromotions(request, env, principal, url.pathname);
      }
      if (["/api/v1/listings", "/api/v1/listings/update", "/api/v1/listings/archive", "/api/v1/listings/movements"].includes(url.pathname)) {
        return await handleListings(request, env, principal, url.pathname);
      }
      if (url.pathname.startsWith("/api/v1/stores/") || url.pathname.startsWith("/api/v1/admin/stores/")) {
        return await handleStores(request, env, principal, url.pathname);
      }
      if (url.pathname === "/api/v1/tours/manage") return await handleTours(request, env, principal);
      if (url.pathname === "/api/v1/admin/storage/orphans/delete") return await handleStorageOrphanDelete(request, env, principal);
      if (url.pathname === "/api/v1/admin/storage/reconcile") return await handleStorageReconciliation(request, env, principal);
      if (url.pathname === "/api/v1/storage/availability") return await handleStorageAvailability(request, env);
      if (url.pathname === "/api/v1/media/reservations") return await reserveMediaUpload(request, env, principal);
      if (url.pathname === "/api/v1/media/finalize") return await finalizeMediaUpload(request, env, principal);
      if (url.pathname === "/api/v1/media/private-access") return await getPrivateMediaAccess(request, env, principal);
      if (url.pathname === "/api/v1/media/delete") return await deleteMediaAsset(request, env, principal);
      if (url.pathname === "/api/v1/admin/media/cleanup-reservations") return await cleanupAbandonedMediaReservations(request, env, principal);
      if (url.pathname === "/api/v1/media/panorama-derivative/reservations") return await reservePanoramaDerivativeUpload(request, env, principal);
      if (url.pathname === "/api/v1/media/panorama-derivative/finalize") return await finalizePanoramaDerivativeUpload(request, env, principal);
      if (url.pathname === "/api/v1/tours/panorama/review") return await recordTourPanoramaReview(request, env, principal);
      if (url.pathname === "/api/v1/tours/panorama/private-access") return await getPanoramaPrivateMediaAccess(request, env, principal);
      if (url.pathname === "/api/v1/tours/panorama/publish") return await publishStoreTour(request, env, principal);
      if (url.pathname === "/api/v1/tours/panorama/published-access") return await getPublishedTourPanoramaAccess(request, env, principal);
      if (url.pathname.startsWith("/api/v1/admin/storage/")) return await handleStorageAdmin(request, env, principal, url.pathname);
      return Response.json({ error: "Route is not yet migrated.", uid: principal.uid }, { status: 501, headers: { "Cache-Control": "no-store" } });
    } catch (error) {
      console.error("API request failed", {
        path: requestPath,
        status: error instanceof ApiError ? error.status : 500,
        kind: error instanceof Error ? error.name : "unknown",
      });
      return errorResponse(error);
    }
  },
  async scheduled(controller: ScheduledController, env: Env, context: ExecutionContext): Promise<void> {
    if (controller.cron === "*/15 * * * *") context.waitUntil(runExpiredMediaCleanup(env));
  },
};
