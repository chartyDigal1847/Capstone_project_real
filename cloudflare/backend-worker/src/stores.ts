import { documentData, FirestoreRest } from "./firestore.js";
import type { Env, Principal } from "./index.js";
import { ApiError } from "./errors.js";
import { reviewStoreApplication as reviewStore } from "./store_review.js";
import { geohash } from "./geohash.js";

const STORE_TYPES = new Set(["sariSari", "fruitVegetable", "marketStall", "streetVendor", "convenience", "supermarket", "generalMerchandise", "hardware", "electronics", "appliance", "clothing", "bookstore", "autoParts", "other"]);

async function body(request: Request): Promise<Record<string, unknown>> {
  try { const value: unknown = await request.json(); if (value && typeof value === "object" && !Array.isArray(value)) return value as Record<string, unknown>; }
  catch { /* bad JSON */ }
  throw new ApiError(400, "A valid JSON object is required.");
}

function text(value: unknown, field: string, max: number, required = false): string {
  if (typeof value !== "string") { if (!required && value == null) return ""; throw new ApiError(400, `${field} must be text.`); }
  const result = value.trim();
  if (result.length > max || (required && !result)) throw new ApiError(400, `${field} is invalid.`);
  return result;
}

function number(value: unknown, field: string, min: number, max: number): number {
  if (typeof value !== "number" || !Number.isFinite(value) || value < min || value > max) throw new ApiError(400, `${field} is outside its valid range.`);
  return value;
}

async function submitApplication(request: Request, env: Env, principal: Principal): Promise<Response> {
  const data = await body(request);
  const db = new FirestoreRest(env);
  const profile = documentData(await db.get(`users/${principal.uid}`));
  if (!profile) throw new ApiError(412, "Your account profile is not ready yet.");
  if (profile.role === "admin") throw new ApiError(412, "Administrators cannot submit store applications.");
  const type = text(data.type, "type", 40, true);
  if (!STORE_TYPES.has(type)) throw new ApiError(400, "Store type is not supported.");
  if (typeof data.is_mobile !== "boolean") throw new ApiError(400, "is_mobile must be a boolean.");
  const name = text(data.name, "name", 80, true);
  const lat = number(data.lat, "lat", -90, 90);
  const lng = number(data.lng, "lng", -180, 180);
  const imageAssetId = data.imageAssetId == null ? "" : text(data.imageAssetId, "imageAssetId", 100);
  const now = new Date();
  const storeDocumentId = crypto.randomUUID();
  const storePath = `stores/${storeDocumentId}`;
  const mediaPath = imageAssetId ? `mediaAssets/${principal.uid}_${imageAssetId}` : undefined;
  const storeId = await db.runTransaction(async (tx) => {
    const ratePath = `systemRateLimits/${principal.uid}_storeApplication`;
    const [rate, pending, sequence] = await Promise.all([
      tx.get(ratePath),
      tx.query("stores", [
        { field: "ownerUid", op: "EQUAL", value: principal.uid },
        { field: "status", op: "EQUAL", value: "pending" },
      ], 1),
      tx.get("systemCounters/storeIds"),
    ]);
    if (pending.length) throw new ApiError(409, "You already have a store application awaiting review.");
    const storedRate = documentData(rate);
    const startedAt = storedRate?.windowStartedAt instanceof Date ? storedRate.windowStartedAt : null;
    const elapsed = startedAt ? now.getTime() - startedAt.getTime() : null;
    const activeWindow = elapsed !== null && elapsed >= 0 && elapsed < 86_400_000;
    const count = activeWindow ? Number(storedRate?.count ?? 0) : 0;
    if (count >= 3) throw new ApiError(429, "You have reached the store application limit. Try again tomorrow.");
    const counter = documentData(sequence);
    const last = counter ? [] : await tx.query("stores", [], 1, [{ field: "numericId", direction: "DESCENDING" }]);
    const id = counter ? Number(counter.value ?? 0) + 1 : Number(documentData(last[0] ?? null)?.numericId ?? 0) + 1;
    if (!Number.isSafeInteger(id) || id <= 0) throw new ApiError(429, "A store ID could not be allocated safely.");
    let media: Record<string, unknown> | null = null;
    if (mediaPath) {
      media = documentData(await tx.get(mediaPath));
      if (!media || media.uid !== principal.uid || media.mediaType !== "store" || media.status !== "ready" || media.linkedStoreId != null || typeof media.privatePath !== "string") {
        throw new ApiError(412, "The store photo has not finished processing or was already used.");
      }
    }
    tx.create(storePath, {
      numericId: id,
      ownerId: Number(profile.numericId ?? 0),
      ownerUid: principal.uid,
      name,
      type,
      status: "pending",
      lat,
      lng,
      geohash: geohash(lat, lng),
      barangay: text(data.barangay, "barangay", 80),
      city: text(data.city, "city", 80),
      address: text(data.address, "address", 160),
      landmark: text(data.landmark, "landmark", 160),
      schedule: text(data.schedule, "schedule", 120),
      is_mobile: data.is_mobile,
      image: "",
      verification_note: text(data.verification_note, "verification_note", 500),
      location_mode: data.is_mobile ? "regular" : "fixed",
      location_updated_at: now.toISOString(),
    });
    if (mediaPath) tx.patch(mediaPath, { linkedStoreId: id, linkedAt: now.toISOString(), updatedAt: now });
    tx.set(ratePath, { uid: principal.uid, operation: "storeApplication", windowStartedAt: activeWindow ? startedAt! : now, count: count + 1, updatedAt: now });
    tx.set("systemCounters/storeIds", { value: id });
    return id;
  });
  return Response.json({ id: storeId, status: "pending" });
}

async function updateStore(request: Request, env: Env, principal: Principal): Promise<Response> {
  const data = await body(request);
  const storeId = data.storeId;
  if (typeof storeId !== "number" || !Number.isSafeInteger(storeId) || storeId <= 0) throw new ApiError(400, "A valid store ID is required.");
  const db = new FirestoreRest(env);
  const doc = (await db.query("stores", [{ field: "numericId", op: "EQUAL", value: storeId }], 1))[0];
  const store = documentData(doc ?? null);
  if (!doc || !store) throw new ApiError(404, "Store was not found.");
  const caller = documentData(await db.get(`users/${principal.uid}`));
  if (store.ownerUid !== principal.uid && caller?.role !== "admin") throw new ApiError(403, "Only the store owner can change its location and details.");
  if (data.type != null && !STORE_TYPES.has(String(data.type))) throw new ApiError(400, "Store type is not supported.");
  if (data.isMobile != null && typeof data.isMobile !== "boolean") throw new ApiError(400, "isMobile must be a boolean.");
  const lat = data.lat == null ? Number(store.lat) : number(data.lat, "lat", -90, 90);
  const lng = data.lng == null ? Number(store.lng) : number(data.lng, "lng", -180, 180);
  const patch: Record<string, unknown> = { lat, lng, geohash: geohash(lat, lng), location_updated_at: new Date().toISOString() };
  if (data.name != null) patch.name = text(data.name, "name", 80, true);
  if (data.type != null) patch.type = text(data.type, "type", 40, true);
  if (data.barangay != null) patch.barangay = text(data.barangay, "barangay", 80);
  if (data.city != null) patch.city = text(data.city, "city", 80);
  if (data.address != null) patch.address = text(data.address, "address", 160);
  if (data.landmark != null) patch.landmark = text(data.landmark, "landmark", 160);
  if (data.schedule != null) patch.schedule = text(data.schedule, "schedule", 120);
  if (data.isMobile != null) patch.is_mobile = data.isMobile;
  const storePath = doc.name.split("/documents/")[1];
  const listings = await db.query("listings", [{ field: "storeId", op: "EQUAL", value: storeId }], 1000);
  await db.runTransaction(async (tx) => {
    tx.patch(storePath, patch);
    for (const listing of listings) tx.patch(listing.name.split("/documents/")[1], { lat, lng, geohash: patch.geohash });
  });
  return Response.json({ ok: true, storeId, geohash: patch.geohash });
}

async function manageMembership(request: Request, env: Env, principal: Principal): Promise<Response> {
  const data = await body(request);
  const storeId = data.storeId;
  if (typeof storeId !== "number" || !Number.isSafeInteger(storeId) || storeId <= 0) throw new ApiError(400, "A valid store ID is required.");
  const email = data.email == null ? "" : text(data.email, "email", 120).toLowerCase();
  const numeric = data.userNumericId;
  if (!email && (typeof numeric !== "number" || !Number.isSafeInteger(numeric) || numeric <= 0)) throw new ApiError(400, "Provide a staff email or user ID.");
  if (data.action !== "set" && data.action !== "remove") throw new ApiError(400, "Action must be set or remove.");
  if (data.action === "set" && [data.inventory, data.promotions, data.location].some((value) => value != null && typeof value !== "boolean")) throw new ApiError(400, "Store grants must be booleans.");
  const db = new FirestoreRest(env);
  const storeDoc = (await db.query("stores", [{ field: "numericId", op: "EQUAL", value: storeId }], 1))[0];
  const store = documentData(storeDoc ?? null);
  if (!store) throw new ApiError(404, "Store was not found.");
  const caller = documentData(await db.get(`users/${principal.uid}`));
  if (caller?.role !== "admin" && store.ownerUid !== principal.uid) throw new ApiError(403, "Only the store owner can manage its staff.");
  const targetDoc = email
    ? (await db.query("users", [{ field: "email", op: "EQUAL", value: email }], 1))[0]
    : (await db.query("users", [{ field: "numericId", op: "EQUAL", value: numeric }], 1))[0];
  const target = documentData(targetDoc ?? null);
  if (!targetDoc || !target) throw new ApiError(404, "No LocalSpot account matches that user.");
  const targetUid = targetDoc.name.split("/").at(-1)!;
  if (targetUid === store.ownerUid) throw new ApiError(412, "The store owner cannot be added as staff.");
  const memberDocs = await db.query("storeMembers", [
    { field: "storeId", op: "EQUAL", value: storeId },
    { field: "userUid", op: "EQUAL", value: targetUid },
  ], 20);
  const memberPath = memberDocs[0]?.name.split("/documents/")[1] ?? `storeMembers/${storeId}_${targetUid}`;
  await db.runTransaction(async (tx) => {
    const currentTarget = documentData(await tx.get(`users/${targetUid}`));
    if (!currentTarget) throw new ApiError(412, "Staff account profile is missing.");
    if (currentTarget.role === "admin") throw new ApiError(412, "Administrators cannot be added as store staff.");
    const memberships = Array.isArray(currentTarget.memberStoreIds) ? currentTarget.memberStoreIds.map(Number) : [];
    const previous = documentData(memberDocs[0] ?? null);
    if (data.action === "set") {
      tx.set(memberPath, {
        storeId,
        email: String(target.email ?? email),
        userUid: targetUid,
        userNumericId: Number(currentTarget.numericId ?? 0),
        inventory: data.inventory == null ? previous?.inventory === true : data.inventory,
        promotions: data.promotions == null ? previous?.promotions === true : data.promotions,
        location: data.location == null ? previous?.location === true : data.location,
      });
      for (const duplicate of memberDocs.slice(1)) tx.delete(duplicate.name.split("/documents/")[1]);
      tx.patch(`users/${targetUid}`, { memberStoreIds: [...new Set([...memberships, storeId])], role: currentTarget.role === "owner" ? "owner" : "staff" });
    } else {
      for (const stale of memberDocs) tx.delete(stale.name.split("/documents/")[1]);
      const remaining = memberships.filter((id) => id !== storeId);
      tx.patch(`users/${targetUid}`, { memberStoreIds: remaining, role: currentTarget.role === "staff" && remaining.length === 0 ? "customer" : currentTarget.role });
    }
    tx.create(`auditLogs/${crypto.randomUUID()}`, { action: `store.membership.${data.action}`, storeId, actorUid: principal.uid, targetUid, created_at: new Date().toISOString() });
  });
  return Response.json({ ok: true, action: data.action, storeId, uid: targetUid });
}

async function listMemberships(request: Request, env: Env, principal: Principal): Promise<Response> {
  const data = await body(request);
  const storeId = data.storeId;
  if (typeof storeId !== "number" || !Number.isSafeInteger(storeId) || storeId <= 0) throw new ApiError(400, "A valid store ID is required.");
  const db = new FirestoreRest(env);
  const store = documentData((await db.query("stores", [{ field: "numericId", op: "EQUAL", value: storeId }], 1))[0] ?? null);
  const caller = documentData(await db.get(`users/${principal.uid}`));
  if (!store || !caller) throw new ApiError(404, "Store was not found.");
  if (store.ownerUid !== principal.uid && caller.role !== "admin") throw new ApiError(403, "Only the store owner or an administrator can view staff.");
  const members = await db.query("storeMembers", [{ field: "storeId", op: "EQUAL", value: storeId }], 100);
  const output = [];
  for (const memberDoc of members) {
    const grants = documentData(memberDoc)!;
    const uid = String(grants.userUid ?? "");
    const profile = documentData(await db.get(`users/${uid}`));
    if (!profile) continue;
    output.push({
      id: Number(profile.numericId ?? 0),
      name: String(profile.name ?? ""),
      email: String(profile.email ?? grants.email ?? ""),
      role: String(profile.role ?? "customer"),
      owned_store_ids: Array.isArray(profile.ownedStoreIds) ? profile.ownedStoreIds : [],
      member_store_ids: Array.isArray(profile.memberStoreIds) ? profile.memberStoreIds : [],
      store_grants: [{ store_id: storeId, inventory: grants.inventory === true, promotions: grants.promotions === true, location: grants.location === true }],
    });
  }
  return Response.json({ members: output });
}

export async function handleStores(request: Request, env: Env, principal: Principal, path: string): Promise<Response> {
  if (request.method !== "POST") return Response.json({ error: "Method not allowed." }, { status: 405, headers: { Allow: "POST" } });
  if (path === "/api/v1/stores/applications") return submitApplication(request, env, principal);
  if (path === "/api/v1/stores/update") return updateStore(request, env, principal);
  if (path === "/api/v1/admin/stores/review") return reviewStore(request, env, principal);
  if (path === "/api/v1/admin/stores/approve") return reviewStore(request, env, principal, "approved");
  if (path === "/api/v1/stores/members/manage") return manageMembership(request, env, principal);
  if (path === "/api/v1/stores/members") return listMemberships(request, env, principal);
  throw new ApiError(404, "Route not found.");
}
