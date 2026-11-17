import { documentData, FirestoreRest } from "./firestore.js";
import type { Env, Principal } from "./index.js";
import { ApiError } from "./errors.js";

const MAX_SESSION_MS = 2 * 60 * 60 * 1000;
const MIN_UPDATE_INTERVAL_MS = 15 * 1000;

function numericId(value: unknown, label: string): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value <= 0) throw new ApiError(400, `A valid ${label} is required.`);
  return value;
}

function coordinates(data: Record<string, unknown>): { lat: number; lng: number } {
  const { lat, lng } = data;
  if (typeof lat !== "number" || !Number.isFinite(lat) || lat < -90 || lat > 90 ||
      typeof lng !== "number" || !Number.isFinite(lng) || lng < -180 || lng > 180) {
    throw new ApiError(400, "Valid latitude and longitude are required.");
  }
  return { lat, lng };
}

async function body(request: Request): Promise<Record<string, unknown>> {
  try {
    const value = await request.json();
    if (value && typeof value === "object" && !Array.isArray(value)) return value as Record<string, unknown>;
  } catch { /* invalid request body */ }
  throw new ApiError(400, "A valid JSON object is required.");
}

async function storeAccess(db: FirestoreRest, uid: string, storeId: number): Promise<{ storeId: number; ownerUid: string }> {
  const stores = await db.query("stores", [{ field: "numericId", op: "EQUAL", value: storeId }], 1);
  const store = documentData(stores[0] ?? null);
  if (!store) throw new ApiError(404, "Store was not found.");
  if (store.status !== "approved") throw new ApiError(412, "The store is not approved.");
  if (store.ownerUid === uid) return { storeId, ownerUid: uid };
  const memberships = await db.query("storeMembers", [
    { field: "storeId", op: "EQUAL", value: storeId },
    { field: "userUid", op: "EQUAL", value: uid },
  ], 1);
  const membership = documentData(memberships[0] ?? null);
  if (membership?.location !== true) throw new ApiError(403, "Location sharing access to this store is required.");
  return { storeId, ownerUid: String(store.ownerUid) };
}

function active(session: Record<string, unknown> | null, now: Date): boolean {
  return !!session && session.ended_at == null && session.expiresAt instanceof Date && session.expiresAt.getTime() > now.getTime();
}

export async function handleVendorLocations(request: Request, env: Env, principal: Principal, path: string): Promise<Response> {
  const db = new FirestoreRest(env);
  if (path === "/api/v1/vendor-locations/active") {
    const now = new Date();
    const sessions = await db.query("vendorSessions", [
      { field: "ended_at", op: "EQUAL", value: null },
      { field: "expiresAt", op: "GREATER_THAN", value: now },
    ], 250);
    const candidates = [...new Set(sessions.map((document) => documentData(document)?.storeId).filter((value): value is number => Number.isSafeInteger(value) && Number(value) > 0))];
    const approved = new Set<number>();
    for (let i = 0; i < candidates.length; i += 30) {
      const stores = await db.query("stores", [
        { field: "status", op: "EQUAL", value: "approved" },
        { field: "numericId", op: "IN", value: candidates.slice(i, i + 30) },
      ], 30);
      for (const store of stores) {
        const id = documentData(store)?.numericId;
        if (typeof id === "number") approved.add(id);
      }
    }
    return Response.json({ sessions: sessions.flatMap((document) => {
      const data = documentData(document)!;
      return approved.has(Number(data.storeId)) ? [{
        id: document.name.split("/").at(-1),
        storeId: data.storeId,
        store_id: data.storeId,
        lat: data.lat,
        lng: data.lng,
        started_at: data.started_at,
        last_update_at: data.last_update_at,
        expires_at: data.expires_at,
      }] : [];
    }) });
  }

  if (!["/api/v1/vendor-locations/sessions/start", "/api/v1/vendor-locations/sessions/update", "/api/v1/vendor-locations/sessions/stop"].includes(path)) {
    throw new ApiError(404, "Route not found.");
  }
  if (request.method !== "POST") return Response.json({ error: "Method not allowed." }, { status: 405, headers: { Allow: "POST" } });
  const data = await body(request);
  const storeId = numericId(data.storeId, "store ID");
  const { lat, lng } = path.endsWith("/stop") ? { lat: 0, lng: 0 } : coordinates(data);
  const { ownerUid } = await storeAccess(db, principal.uid, storeId);
  const sessionPath = `vendorSessions/${storeId}`;
  const now = new Date();

  if (path.endsWith("/start")) {
    const session = {
      numericId: storeId,
      storeId,
      lat,
      lng,
      started_at: now.toISOString(),
      last_update_at: now.toISOString(),
      expires_at: new Date(now.getTime() + MAX_SESSION_MS).toISOString(),
      expiresAt: new Date(now.getTime() + MAX_SESSION_MS),
      ended_at: null,
      ownerUid,
      startedByUid: principal.uid,
    };
    await db.runTransaction(async (tx) => {
      const current = documentData(await tx.get(sessionPath));
      if (active(current, now)) throw new ApiError(409, "A live location session is already active for this store.");
      tx.set(sessionPath, session);
      tx.create(`auditLogs/${crypto.randomUUID()}`, { action: "vendorLocation.started", storeId, actorUid: principal.uid, created_at: now.toISOString() });
    });
    return Response.json({ ...session, expiresAt: session.expiresAt.toISOString(), store_id: storeId });
  }

  if (path.endsWith("/update")) {
    await db.runTransaction(async (tx) => {
      const session = documentData(await tx.get(sessionPath));
      if (!active(session, now)) throw new ApiError(412, "There is no active location session.");
      if (session!.startedByUid !== principal.uid) throw new ApiError(403, "Only the session starter can update its location.");
      const lastUpdate = Date.parse(String(session!.last_update_at ?? ""));
      if (Number.isFinite(lastUpdate) && now.getTime() - lastUpdate < MIN_UPDATE_INTERVAL_MS) throw new ApiError(429, "Wait before sending another location update.");
      tx.patch(sessionPath, {
        lat,
        lng,
        last_update_at: now.toISOString(),
        expires_at: new Date(now.getTime() + MAX_SESSION_MS).toISOString(),
        expiresAt: new Date(now.getTime() + MAX_SESSION_MS),
      });
    });
    return Response.json({ ok: true, storeId });
  }

  await db.runTransaction(async (tx) => {
    const session = documentData(await tx.get(sessionPath));
    if (!session || session.ended_at != null) return;
    if (session.startedByUid !== principal.uid) throw new ApiError(403, "Only the session starter can stop this session.");
    tx.patch(sessionPath, { ended_at: now.toISOString() });
    tx.create(`auditLogs/${crypto.randomUUID()}`, { action: "vendorLocation.stopped", storeId, actorUid: principal.uid, created_at: now.toISOString() });
  });
  return Response.json({ ok: true, storeId });
}
