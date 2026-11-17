import { documentData, FirestoreRest } from "./firestore.js";
import type { Env, Principal } from "./index.js";
import { ApiError } from "./errors.js";

const AVAILABILITY = new Set(["in_stock", "low", "unavailable"]);
const LISTING_STATUS = new Set(["active", "archived", "unavailable"]);

async function jsonBody(request: Request): Promise<Record<string, unknown>> {
  try { const value: unknown = await request.json(); if (value && typeof value === "object" && !Array.isArray(value)) return value as Record<string, unknown>; }
  catch { /* bad request body */ }
  throw new ApiError(400, "A valid JSON object is required.");
}

function string(value: unknown, field: string, max: number, required = false): string {
  if (typeof value !== "string") {
    if (!required && value == null) return "";
    throw new ApiError(400, `${field} must be text.`);
  }
  const result = value.trim();
  if (result.length > max || (required && !result)) throw new ApiError(400, `${field} is invalid.`);
  return result;
}

function amount(value: unknown, field: string, min: number, max: number): number {
  if (typeof value !== "number" || !Number.isFinite(value) || value < min || value > max) throw new ApiError(400, `${field} is outside its valid range.`);
  return value;
}

function encodeGeohash(latitude: number, longitude: number, precision = 4): string {
  const base32 = "0123456789bcdefghjkmnpqrstuvwxyz";
  let south = -90, north = 90, west = -180, east = 180, even = true, bits = 0, value = 0, hash = "";
  while (hash.length < precision) {
    const midpoint = even ? (west + east) / 2 : (south + north) / 2;
    const upper = (even ? longitude : latitude) >= midpoint;
    value = (value << 1) | (upper ? 1 : 0);
    if (even) upper ? west = midpoint : east = midpoint;
    else upper ? south = midpoint : north = midpoint;
    even = !even;
    if (++bits === 5) { hash += base32[value]; bits = 0; value = 0; }
  }
  return hash;
}

function searchPrefixes(values: string[]): string[] {
  const normalize = (value: string) => value.toLowerCase().replace(/[^a-z0-9]+/g, " ").trim().replace(/\s+/g, " ");
  const prefixes = new Set<string>();
  const variants = values.map(normalize).filter(Boolean).flatMap((phrase) => {
    const words = phrase.split(" ");
    return words.map((_, start) => words.slice(start).join(" "));
  });
  const add = (value: string) => { const bounded = value.slice(0, 80); if (bounded.length >= 2) prefixes.add(bounded); };
  for (const variant of variants) {
    add(variant);
    for (const word of variant.split(" ")) add(word);
    if (prefixes.size >= 200) return [...prefixes].slice(0, 200);
  }
  for (let length = 2; length <= 80; length++) {
    for (const variant of variants) {
      if (variant.length >= length) add(variant.slice(0, length));
      if (prefixes.size >= 200) return [...prefixes].slice(0, 200);
    }
  }
  return [...prefixes];
}

async function storeAndGrant(db: FirestoreRest, uid: string, storeId: number): Promise<Record<string, unknown>> {
  const result = (await db.query("stores", [{ field: "numericId", op: "EQUAL", value: storeId }], 1))[0];
  const store = documentData(result ?? null);
  if (!store) throw new ApiError(404, "Store was not found.");
  if (store.status !== "approved") throw new ApiError(412, "The store is not approved.");
  if (store.ownerUid === uid) return store;
  const memberships = await db.query("storeMembers", [
    { field: "storeId", op: "EQUAL", value: storeId },
    { field: "userUid", op: "EQUAL", value: uid },
  ], 1);
  if (documentData(memberships[0] ?? null)?.inventory !== true) throw new ApiError(403, "inventory access to this store is required.");
  return store;
}

async function nextId(db: FirestoreRest, collection: string, counterName: string): Promise<number> {
  return db.runTransaction(async (tx) => {
    const counter = documentData(await tx.get(`systemCounters/${counterName}`));
    let value: number;
    if (counter) value = Number(counter.value ?? 0) + 1;
    else {
      const highest = await tx.query(collection, [], 1, [{ field: "numericId", direction: "DESCENDING" }]);
      value = Number(documentData(highest[0] ?? null)?.numericId ?? 0) + 1;
    }
    if (!Number.isSafeInteger(value) || value <= 0) throw new ApiError(503, "A new catalog ID could not be allocated safely.");
    tx.set(`systemCounters/${counterName}`, { value });
    return value;
  });
}

async function createListing(request: Request, env: Env, principal: Principal): Promise<Response> {
  const data = await jsonBody(request);
  const db = new FirestoreRest(env);
  const storeId = amount(data.storeId, "storeId", 1, Number.MAX_SAFE_INTEGER);
  if (!Number.isSafeInteger(storeId)) throw new ApiError(400, "storeId must be an integer.");
  const store = await storeAndGrant(db, principal.uid, storeId);
  const price = amount(data.price, "price", 0, 1_000_000);
  const quantity = amount(data.quantity ?? 0, "quantity", 0, 100_000);
  const unit = string(data.unit, "unit", 40, true);
  const availability = string(data.availability ?? "in_stock", "availability", 20, true);
  if (!AVAILABILITY.has(availability)) throw new ApiError(400, "Availability is not supported.");

  let productId = data.productId;
  let productData: Record<string, unknown> | undefined;
  let mediaPath: string | undefined;
  let productImage = "";
  if (data.imageAssetId != null) {
    if (productId != null || typeof data.imageAssetId !== "string" || !/^[A-Za-z0-9_-]{1,100}$/.test(data.imageAssetId)) throw new ApiError(400, "A new product image requires a new product listing.");
    mediaPath = `mediaAssets/${principal.uid}_${data.imageAssetId}`;
    const media = documentData(await db.get(mediaPath));
    if (!media || media.uid !== principal.uid || media.status !== "ready" || typeof media.downloadUrl !== "string" ||
        typeof media.publicPath !== "string" || !media.publicPath.startsWith(`products/public/${principal.uid}/`)) {
      throw new ApiError(412, "The product image has not finished processing.");
    }
    productImage = media.downloadUrl;
  }
  if (productId != null) {
    if (typeof productId !== "number" || !Number.isSafeInteger(productId) || productId <= 0) throw new ApiError(400, "productId must be a valid catalog ID.");
    if (!(await db.query("products", [{ field: "numericId", op: "EQUAL", value: productId }], 1)).length) throw new ApiError(404, "Product was not found.");
  } else {
    const name = string(data.name, "name", 80, true);
    const category = string(data.category ?? "Groceries", "category", 40, true);
    productId = await nextId(db, "products", "productIds");
    const brand = string(data.brand, "brand", 80);
    const attributes = data.attributes && typeof data.attributes === "object" && !Array.isArray(data.attributes) ? data.attributes as Record<string, unknown> : {};
    productData = {
      numericId: productId,
      name,
      category,
      brand,
      package_size: string(data.packageSize, "packageSize", 60),
      aliases: [name],
      barcode: string(data.barcode, "barcode", 80),
      image: productImage,
      attributes,
      searchPrefixes: searchPrefixes([name, brand, category, ...Object.values(attributes).map(String), name]),
      createdByUid: principal.uid,
    };
  }

  const listingId = await nextId(db, "listings", "listingIds");
  const listingDoc = crypto.randomUUID();
  const productDoc = productData ? crypto.randomUUID() : undefined;
  const movementId = crypto.randomUUID();
  const now = new Date().toISOString();
  await db.runTransaction(async (tx) => {
    if (mediaPath) {
      const media = documentData(await tx.get(mediaPath));
      if (!media || media.uid !== principal.uid || media.status !== "ready" || media.linkedProductId != null || media.downloadUrl !== productImage) throw new ApiError(412, "This product image has already been used or is no longer available.");
      tx.patch(mediaPath, { linkedProductId: productId, linkedAt: now, updatedAt: new Date() });
    }
    if (productData && productDoc) tx.create(`products/${productDoc}`, productData);
    tx.create(`listings/${listingDoc}`, {
      numericId: listingId,
      storeId,
      lat: Number(store.lat),
      lng: Number(store.lng),
      geohash: encodeGeohash(Number(store.lat), Number(store.lng)),
      productId,
      price,
      unit,
      quantity,
      availability,
      last_confirmed_at: now,
      status: "active",
      ownerUid: principal.uid,
    });
    tx.create(`stockMovements/${movementId}`, { listingId, kind: "add", quantity_delta: quantity, note: "Owner confirmed listing", created_at: now, ownerUid: principal.uid });
  });
  return Response.json({ id: listingId, productId });
}

async function updateListing(request: Request, env: Env, principal: Principal): Promise<Response> {
  const data = await jsonBody(request);
  const listingId = amount(data.listingId, "listingId", 1, Number.MAX_SAFE_INTEGER);
  if (!Number.isSafeInteger(listingId)) throw new ApiError(400, "listingId must be an integer.");
  const db = new FirestoreRest(env);
  const doc = (await db.query("listings", [{ field: "numericId", op: "EQUAL", value: listingId }], 1))[0];
  const existing = documentData(doc ?? null);
  if (!doc || !existing) throw new ApiError(404, "Listing was not found.");
  await storeAndGrant(db, principal.uid, Number(existing.storeId));
  const quantity = data.quantity == null ? Number(existing.quantity ?? 0) : amount(data.quantity, "quantity", 0, 100_000);
  const price = data.price == null ? Number(existing.price ?? 0) : amount(data.price, "price", 0, 1_000_000);
  const availability = data.availability == null ? String(existing.availability) : string(data.availability, "availability", 20, true);
  const status = data.status == null ? String(existing.status) : string(data.status, "status", 20, true);
  if (!AVAILABILITY.has(availability) || !LISTING_STATUS.has(status)) throw new ApiError(400, "Availability or listing status is not supported.");
  const unit = data.unit == null ? String(existing.unit) : string(data.unit, "unit", 40, true);
  const path = doc.name.split("/documents/")[1];
  const now = new Date().toISOString();
  await db.runTransaction(async (tx) => {
    tx.patch(path, { price, quantity, unit, availability, status, last_confirmed_at: now });
    const delta = quantity - Number(existing.quantity ?? 0);
    if (delta !== 0 || status !== existing.status) tx.create(`stockMovements/${crypto.randomUUID()}`, {
      listingId,
      kind: status === "archived" ? "archive" : "adjust",
      quantity_delta: delta,
      note: status === "unavailable" ? "Marked unavailable" : "Stock update",
      created_at: now,
      ownerUid: principal.uid,
    });
  });
  return Response.json({ ok: true, id: listingId });
}

async function archiveListing(request: Request, env: Env, principal: Principal): Promise<Response> {
  const data = await jsonBody(request);
  const listingId = amount(data.listingId, "listingId", 1, Number.MAX_SAFE_INTEGER);
  if (!Number.isSafeInteger(listingId)) throw new ApiError(400, "listingId must be an integer.");
  const db = new FirestoreRest(env);
  const doc = (await db.query("listings", [{ field: "numericId", op: "EQUAL", value: listingId }], 1))[0];
  const listing = documentData(doc ?? null);
  if (!doc || !listing) throw new ApiError(404, "Listing was not found.");
  await storeAndGrant(db, principal.uid, Number(listing.storeId));
  if (listing.status === "archived") return Response.json({ ok: true, id: listingId });
  const path = doc.name.split("/documents/")[1];
  const now = new Date().toISOString();
  await db.runTransaction(async (tx) => {
    tx.patch(path, { status: "archived", last_confirmed_at: now });
    tx.create(`stockMovements/${crypto.randomUUID()}`, { listingId, kind: "archive", quantity_delta: 0, note: "Listing archived", created_at: now, ownerUid: principal.uid });
  });
  return Response.json({ ok: true, id: listingId });
}

async function movements(request: Request, env: Env, principal: Principal): Promise<Response> {
  const data = await jsonBody(request);
  const listingId = amount(data.listingId, "listingId", 1, Number.MAX_SAFE_INTEGER);
  if (!Number.isSafeInteger(listingId)) throw new ApiError(400, "listingId must be an integer.");
  const db = new FirestoreRest(env);
  const listing = documentData((await db.query("listings", [{ field: "numericId", op: "EQUAL", value: listingId }], 1))[0] ?? null);
  if (!listing) throw new ApiError(404, "Listing was not found.");
  await storeAndGrant(db, principal.uid, Number(listing.storeId));
  const entries = await db.query("stockMovements", [{ field: "listingId", op: "EQUAL", value: listingId }], 100, undefined, [{ field: "created_at", direction: "DESCENDING" }]);
  return Response.json({ movements: entries.map((entry) => {
    const value = documentData(entry)!;
    return { kind: value.kind, quantity_delta: value.quantity_delta, note: value.note, created_at: value.created_at };
  }) });
}

export async function handleListings(request: Request, env: Env, principal: Principal, path: string): Promise<Response> {
  if (request.method !== "POST") return Response.json({ error: "Method not allowed." }, { status: 405, headers: { Allow: "POST" } });
  if (path === "/api/v1/listings") return createListing(request, env, principal);
  if (path === "/api/v1/listings/update") return updateListing(request, env, principal);
  if (path === "/api/v1/listings/archive") return archiveListing(request, env, principal);
  if (path === "/api/v1/listings/movements") return movements(request, env, principal);
  throw new ApiError(404, "Route not found.");
}
