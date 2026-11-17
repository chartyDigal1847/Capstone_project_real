import { documentData, FirestoreRest, type FirestoreWrite } from "./firestore.js";
import type { Env, Principal } from "./index.js";
import { ApiError } from "./errors.js";
import { deleteStoredObject } from "./storage_orphans.js";

const RECENT_AUTH_SECONDS = 5 * 60;
const ACCOUNT_DELETE_URL = "https://identitytoolkit.googleapis.com/v1/accounts:delete";

function documentPath(name: string): string {
  const marker = "/documents/", index = name.indexOf(marker);
  if (index < 0) throw new ApiError(500, "A Firestore document path is invalid.");
  return name.slice(index + marker.length);
}

async function commitDeletes(db: FirestoreRest, documents: Array<{ name: string }>): Promise<void> {
  for (let index = 0; index < documents.length; index += 400) {
    const writes: FirestoreWrite[] = documents.slice(index, index + 400).map((doc) => ({ delete: doc.name }));
    if (writes.length) await db.commit(writes);
  }
}

async function deleteMatching(db: FirestoreRest, collection: string, field: string, uid: string): Promise<void> {
  while (true) {
    const matches = await db.query(collection, [{ field, op: "EQUAL", value: uid }], 400);
    if (matches.length === 0) return;
    await commitDeletes(db, matches);
  }
}

export function accountMediaObjectKeys(uid: string, media: Record<string, unknown>, derivatives: Array<Record<string, unknown>>): string[] {
  const prefixes = [
    `products/quarantine/${uid}/`, `products/public/${uid}/`, `stores/quarantine/${uid}/`,
    `stores/processed/${uid}/`, `tours/originals/${uid}/`, `tours/derivatives/${uid}/`,
  ];
  const candidates = [media.quarantinePath, media.publicPath, media.privatePath, media.originalPath,
    media.pendingOutputPath, media.pendingPublicPath, media.objectKey, media.latestDerivativeObjectKey,
    ...derivatives.map((derivative) => derivative.objectKey)];
  return [...new Set(candidates.filter((key): key is string =>
    typeof key === "string" && prefixes.some((prefix) => key.startsWith(prefix))))];
}

async function cleanProductMedia(db: FirestoreRest, env: Env, uid: string): Promise<void> {
  while (true) {
    const matches = await db.query("mediaAssets", [{ field: "uid", op: "EQUAL", value: uid }], 300);
    if (matches.length === 0) return;
    for (const doc of matches) {
      const data = documentData(doc)!, path = documentPath(doc.name), now = new Date();
      if (data.status === "ready" && data.linkedProductId != null) {
        await db.runTransaction(async (tx) => {
          if (await tx.get(path)) tx.patch(path, { uid: null, uploaderDeletedAt: now });
        });
        continue;
      }
      const derivativeDocs = await db.listSubcollection(path, "derivatives", 1000);
      const keys = accountMediaObjectKeys(uid, data, derivativeDocs.map((derivative) => documentData(derivative) ?? {}));
      await db.runTransaction(async (tx) => {
        if (await tx.get(path)) tx.patch(path, { status: "deleting", cleanupStartedAt: now });
      });
      for (const key of new Set(keys)) await deleteStoredObject(db, env, key, "system:account-cleanup", "account-deletion");
      for (const derivative of derivativeDocs) {
        const derivativePath = documentPath(derivative.name);
        await db.runTransaction(async (tx) => {
          if (await tx.get(derivativePath)) tx.patch(derivativePath, { status: "deleted", accountingState: "deleted", deletedAt: new Date() });
        });
      }
      await db.runTransaction(async (tx) => {
        if (await tx.get(path)) tx.patch(path, {
          status: "deleted", accountingState: "deleted", deletedAt: new Date(), uid: null,
          uploaderDeletedAt: new Date(), updatedAt: new Date(),
        });
      });
    }
  }
}

async function deleteOwnedTours(db: FirestoreRest, env: Env, uid: string): Promise<void> {
  while (true) {
    const tours = await db.query("tours", [{ field: "ownerUid", op: "EQUAL", value: uid }], 100, undefined, [{ field: "__name__", direction: "ASCENDING" }]);
    if (tours.length === 0) return;
    const keys = new Set<string>();
    for (const tour of tours) {
      const nodes = documentData(tour)?.nodes;
      if (!Array.isArray(nodes)) continue;
      for (const item of nodes) {
        if (!item || typeof item !== "object") continue;
        const key = (item as Record<string, unknown>).original_path;
        if (typeof key === "string" && key.startsWith(`tours/originals/${uid}/`)) keys.add(key);
      }
    }
    for (const key of keys) await deleteStoredObject(db, env, key, "system:account-cleanup", "account-tour-deletion");
    await commitDeletes(db, tours);
  }
}

async function deleteAuthUser(request: Request, env: Env): Promise<void> {
  const authorization = request.headers.get("Authorization") ?? "";
  const token = authorization.match(/^Bearer ([A-Za-z0-9._~-]+)$/)?.[1];
  if (!token) throw new ApiError(401, "A Firebase ID token is required.");
  const apiKey = env.FIREBASE_WEB_API_KEY ?? (env.LOCAL_EMULATORS === "true" ? "emulator" : "");
  if (!apiKey) throw new ApiError(503, "Firebase Auth deletion is not configured.");
  const endpoint = new URL(ACCOUNT_DELETE_URL);
  if (env.LOCAL_EMULATORS === "true") {
    if (!env.FIREBASE_AUTH_EMULATOR_URL || env.FIREBASE_PROJECT_ID !== "demo-localspot") throw new ApiError(503, "Auth emulator configuration is invalid.");
    endpoint.protocol = new URL(env.FIREBASE_AUTH_EMULATOR_URL).protocol;
    endpoint.host = new URL(env.FIREBASE_AUTH_EMULATOR_URL).host;
    endpoint.pathname = "/identitytoolkit.googleapis.com/v1/accounts:delete";
  }
  endpoint.searchParams.set("key", apiKey);
  let response: Response;
  try {
    response = await fetch(endpoint, {
      method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ idToken: token }),
      signal: AbortSignal.timeout(8_000),
    });
  } catch {
    throw new ApiError(503, "Firebase Auth is temporarily unavailable. Retry account deletion.");
  }
  if (response.ok) return;
  let reason = "";
  try { reason = String((await response.json() as { error?: { message?: string } }).error?.message ?? ""); } catch { /* ignore response body */ }
  if (response.status === 401 || /INVALID_ID_TOKEN|USER_NOT_FOUND|TOKEN_EXPIRED/i.test(reason)) {
    throw new ApiError(401, "The Firebase account session expired. Sign in again before deleting your account.");
  }
  throw new ApiError(503, "Firebase Auth could not delete the account. Retry account deletion.");
}

export async function deleteUserAccount(request: Request, env: Env, principal: Principal): Promise<Response> {
  if (request.method !== "POST") return Response.json({ error: "Method not allowed." }, { status: 405, headers: { Allow: "POST" } });
  const now = Math.floor(Date.now() / 1000);
  if (!Number.isFinite(principal.authTime) || now - principal.authTime > RECENT_AUTH_SECONDS || principal.authTime > now + 60) {
    throw new ApiError(412, "Sign in again before deleting your account.");
  }
  const db = new FirestoreRest(env), profilePath = `users/${principal.uid}`;
  const [profileDoc, ownedStores] = await Promise.all([
    db.get(profilePath), db.query("stores", [{ field: "ownerUid", op: "EQUAL", value: principal.uid }], 1000),
  ]);
  if (documentData(profileDoc)?.role === "admin") throw new ApiError(412, "Administrator accounts cannot be deleted in the app.");
  if (ownedStores.some((store) => ["approved", "suspended"].includes(String(documentData(store)?.status)))) {
    throw new ApiError(412, "Transfer store ownership before deleting this account.");
  }

  await Promise.all([
    deleteMatching(db, "favorites", "uid", principal.uid),
    deleteMatching(db, "feedback", "uid", principal.uid),
    deleteMatching(db, "reports", "uid", principal.uid),
    deleteMatching(db, "storeMembers", "userUid", principal.uid),
    deleteMatching(db, "systemRateLimits", "uid", principal.uid),
    cleanProductMedia(db, env, principal.uid),
    deleteOwnedTours(db, env, principal.uid),
  ]);
  await commitDeletes(db, ownedStores);

  while (true) {
    const sessions = await db.query("vendorSessions", [{ field: "startedByUid", op: "EQUAL", value: principal.uid }], 400);
    if (sessions.length === 0) break;
    const nowText = new Date().toISOString();
    await db.runTransaction(async (tx) => {
      for (const session of sessions) tx.patch(documentPath(session.name), { lat: null, lng: null, ended_at: nowText, startedByUid: null });
    });
  }
  await db.commit([{ delete: `projects/${env.FIREBASE_PROJECT_ID}/databases/(default)/documents/${profilePath}` }]);
  await deleteAuthUser(request, env);
  return Response.json({ ok: true }, { headers: { "Cache-Control": "no-store" } });
}
