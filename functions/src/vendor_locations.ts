import { Timestamp } from "firebase-admin/firestore";
import { HttpsError, onCall } from "firebase-functions/v2/https";
import { db, objectData } from "./admin";
import { enforceCallableAppCheck } from "./callable_options";

const CALLABLE_OPTIONS = { region: "asia-southeast1", enforceAppCheck: enforceCallableAppCheck };
const MAX_SESSION_MS = 2 * 60 * 60 * 1000;
const MIN_UPDATE_INTERVAL_MS = 15 * 1000;

export const listActiveVendorLocations = onCall(CALLABLE_OPTIONS, async () => {
  const now = Timestamp.now();
  const active = await db
    .collection("vendorSessions")
    .where("ended_at", "==", null)
    .where("expiresAt", ">", now)
    .limit(250)
    .get();
  const candidateStoreIds = [
    ...new Set(
      active.docs
        .map((doc) => doc.data().storeId)
        .filter((storeId): storeId is number =>
          Number.isSafeInteger(storeId) && storeId > 0,
        ),
    ),
  ];
  const approvedStoreIds = new Set<number>();
  for (let index = 0; index < candidateStoreIds.length; index += 30) {
    const batch = candidateStoreIds.slice(index, index + 30);
    const stores = await db
      .collection("stores")
      .where("status", "==", "approved")
      .where("numericId", "in", batch)
      .get();
    for (const store of stores.docs) {
      const storeId = store.data().numericId;
      if (typeof storeId === "number") approvedStoreIds.add(storeId);
    }
  }

  return {
    sessions: active.docs.filter((doc) => approvedStoreIds.has(doc.data().storeId)).map((doc) => {
      const data = doc.data();
      return {
        id: doc.id,
        storeId: data.storeId,
        store_id: data.storeId,
        lat: data.lat,
        lng: data.lng,
        started_at: data.started_at,
        last_update_at: data.last_update_at,
        expires_at: data.expires_at,
      };
    }),
  };
});

function sessionExpiryMs(session: FirebaseFirestore.DocumentData | undefined): number {
  if (session?.expiresAt instanceof Timestamp) return session.expiresAt.toMillis();
  return Date.parse(String(session?.expires_at ?? ""));
}

function uidFor(request: { auth?: { uid: string } | null }): string {
  if (!request.auth?.uid) throw new HttpsError("unauthenticated", "Sign in to continue.");
  return request.auth.uid;
}

function coordinates(data: Record<string, unknown>) {
  const lat = data.lat;
  const lng = data.lng;
  if (typeof lat !== "number" || !Number.isFinite(lat) || lat < -90 || lat > 90 ||
      typeof lng !== "number" || !Number.isFinite(lng) || lng < -180 || lng > 180) {
    throw new HttpsError("invalid-argument", "Valid latitude and longitude are required.");
  }
  return { lat, lng };
}

async function authorizedStore(uid: string, storeId: unknown) {
  if (typeof storeId !== "number" || !Number.isSafeInteger(storeId) || storeId <= 0) {
    throw new HttpsError("invalid-argument", "A valid store ID is required.");
  }
  const stores = await db.collection("stores").where("numericId", "==", storeId).limit(1).get();
  if (stores.empty) throw new HttpsError("not-found", "Store was not found.");
  const store = stores.docs[0].data();
  if (store.status !== "approved") throw new HttpsError("failed-precondition", "The store is not approved.");
  if (store.ownerUid === uid) return { storeId, ownerUid: uid };
  const members = await db.collection("storeMembers")
    .where("storeId", "==", storeId)
    .where("userUid", "==", uid)
    .limit(1)
    .get();
  if (members.empty || members.docs[0].data().location !== true) {
    throw new HttpsError("permission-denied", "Location sharing access to this store is required.");
  }
  return { storeId, ownerUid: String(store.ownerUid) };
}

export const startVendorLocationSession = onCall(CALLABLE_OPTIONS, async (request) => {
  const uid = uidFor(request);
  const data = objectData(request.data, "Vendor location session");
  const { lat, lng } = coordinates(data);
  const { storeId, ownerUid } = await authorizedStore(uid, data.storeId);
  const ref = db.collection("vendorSessions").doc(String(storeId));
  const now = Timestamp.now();
  const session = {
    numericId: storeId,
    storeId,
    lat,
    lng,
    started_at: now.toDate().toISOString(),
    last_update_at: now.toDate().toISOString(),
    expires_at: Timestamp.fromMillis(now.toMillis() + MAX_SESSION_MS).toDate().toISOString(),
    expiresAt: Timestamp.fromMillis(now.toMillis() + MAX_SESSION_MS),
    ended_at: null,
    ownerUid,
    startedByUid: uid,
  };
  await db.runTransaction(async (transaction) => {
    const current = await transaction.get(ref);
    if (current.exists && current.data()?.ended_at == null && sessionExpiryMs(current.data()) > now.toMillis()) {
      throw new HttpsError("already-exists", "A live location session is already active for this store.");
    }
    transaction.set(ref, session);
    transaction.create(db.collection("auditLogs").doc(), {
      action: "vendorLocation.started",
      storeId,
      actorUid: uid,
      created_at: now.toDate().toISOString(),
    });
  });
  return { ...session, expiresAt: session.expiresAt.toDate().toISOString(), store_id: storeId };
});

export const updateVendorLocationSession = onCall(CALLABLE_OPTIONS, async (request) => {
  const uid = uidFor(request);
  const data = objectData(request.data, "Vendor location update");
  const { lat, lng } = coordinates(data);
  const { storeId } = await authorizedStore(uid, data.storeId);
  const ref = db.collection("vendorSessions").doc(String(storeId));
  const now = Timestamp.now();
  await db.runTransaction(async (transaction) => {
    const current = await transaction.get(ref);
    const session = current.data();
    if (!current.exists || session?.ended_at != null || sessionExpiryMs(session) <= now.toMillis()) {
      throw new HttpsError("failed-precondition", "There is no active location session.");
    }
    if (session?.startedByUid !== uid) throw new HttpsError("permission-denied", "Only the session starter can update its location.");
    const lastUpdate = Date.parse(String(session.last_update_at ?? ""));
    if (Number.isFinite(lastUpdate) && now.toMillis() - lastUpdate < MIN_UPDATE_INTERVAL_MS) {
      throw new HttpsError("resource-exhausted", "Wait before sending another location update.");
    }
    transaction.update(ref, {
      lat,
      lng,
      last_update_at: now.toDate().toISOString(),
      expires_at: Timestamp.fromMillis(now.toMillis() + MAX_SESSION_MS).toDate().toISOString(),
      expiresAt: Timestamp.fromMillis(now.toMillis() + MAX_SESSION_MS),
    });
  });
  return { ok: true, storeId };
});

export const stopVendorLocationSession = onCall(CALLABLE_OPTIONS, async (request) => {
  const uid = uidFor(request);
  const data = objectData(request.data, "Vendor location session");
  const { storeId } = await authorizedStore(uid, data.storeId);
  const ref = db.collection("vendorSessions").doc(String(storeId));
  const now = Timestamp.now();
  await db.runTransaction(async (transaction) => {
    const current = await transaction.get(ref);
    const session = current.data();
    if (!current.exists || session?.ended_at != null) return;
    if (session?.startedByUid !== uid) throw new HttpsError("permission-denied", "Only the session starter can stop this session.");
    transaction.update(ref, { ended_at: now.toDate().toISOString() });
    transaction.create(db.collection("auditLogs").doc(), {
      action: "vendorLocation.stopped",
      storeId,
      actorUid: uid,
      created_at: now.toDate().toISOString(),
    });
  });
  return { ok: true, storeId };
});
