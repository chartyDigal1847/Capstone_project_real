import { Timestamp, type DocumentReference } from "firebase-admin/firestore";
import { HttpsError, onCall } from "firebase-functions/v2/https";
import { db, objectData } from "./admin";
import { encodeGeohash } from "./geo";
import { enforceCallableAppCheck } from "./callable_options";

const CALLABLE_OPTIONS = { region: "asia-southeast1", enforceAppCheck: enforceCallableAppCheck };
const AVAILABILITY = new Set(["in_stock", "low", "unavailable"]);
const LISTING_STATUS = new Set(["active", "archived", "unavailable"]);

function normalizedSearchText(value: string): string {
  return value.toLowerCase().replace(/[^a-z0-9]+/g, " ").trim().replace(/\s+/g, " ");
}

function searchPrefixes(values: string[]): string[] {
  const prefixes = new Set<string>();
  const variants = values
    .map(normalizedSearchText)
    .filter(Boolean)
    .flatMap((phrase) => {
      const words = phrase.split(" ");
      return words.map((_, start) => words.slice(start).join(" "));
    });
  const add = (value: string) => {
    const bounded = value.slice(0, 80);
    if (bounded.length >= 2) prefixes.add(bounded);
  };

  // Preserve every complete phrase and word before spending the bounded field
  // budget on partial prefixes. This keeps brand/category/attribute terms
  // searchable even when the product name has many tokens.
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

function uidFor(request: { auth?: { uid: string } | null }): string {
  if (!request.auth?.uid) throw new HttpsError("unauthenticated", "Sign in to continue.");
  return request.auth.uid;
}

function stringField(value: unknown, field: string, max: number, required = false): string {
  if (typeof value !== "string") {
    if (!required && value == null) return "";
    throw new HttpsError("invalid-argument", `${field} must be text.`);
  }
  const result = value.trim();
  if (result.length > max || (required && result.length === 0)) {
    throw new HttpsError("invalid-argument", `${field} is invalid.`);
  }
  return result;
}

function amount(value: unknown, field: string, min: number, max: number): number {
  if (typeof value !== "number" || !Number.isFinite(value) || value < min || value > max) {
    throw new HttpsError("invalid-argument", `${field} is outside its valid range.`);
  }
  return value;
}

export async function nextId(collectionName: string, counterName: string): Promise<number> {
  const counterRef = db.collection("systemCounters").doc(counterName);
  return db.runTransaction(async (transaction) => {
    const counter = await transaction.get(counterRef);
    let next: number;
    if (counter.exists) {
      next = Number(counter.data()?.value ?? 0) + 1;
    } else {
      const highest = await transaction.get(
        db.collection(collectionName).orderBy("numericId", "desc").limit(1),
      );
      next = Number(highest.docs[0]?.data().numericId ?? 0) + 1;
    }
    transaction.set(counterRef, { value: next });
    return next;
  });
}

export async function storeAndGrant(uid: string, storeId: number, requiredGrant = "inventory") {
  const stores = await db.collection("stores").where("numericId", "==", storeId).limit(1).get();
  if (stores.empty) throw new HttpsError("not-found", "Store was not found.");
  const store = stores.docs[0].data();
  if (store.status !== "approved") throw new HttpsError("failed-precondition", "The store is not approved.");
  if (store.ownerUid === uid) return { ref: stores.docs[0].ref, store };

  const member = await db.collection("storeMembers")
    .where("storeId", "==", storeId)
    .where("userUid", "==", uid)
    .limit(1)
    .get();
  if (member.empty || member.docs[0].data()[requiredGrant] !== true) {
    throw new HttpsError("permission-denied", `${requiredGrant} access to this store is required.`);
  }
  return { ref: stores.docs[0].ref, store };
}

export const createStoreListing = onCall(CALLABLE_OPTIONS, async (request) => {
  const uid = uidFor(request);
  const data = objectData(request.data, "Listing details");
  const storeId = amount(data?.storeId, "storeId", 1, Number.MAX_SAFE_INTEGER);
  if (!Number.isSafeInteger(storeId)) throw new HttpsError("invalid-argument", "storeId must be an integer.");
  const { store } = await storeAndGrant(uid, storeId);

  const price = amount(data.price, "price", 0, 1_000_000);
  const quantity = amount(data.quantity ?? 0, "quantity", 0, 100_000);
  const unit = stringField(data.unit, "unit", 40, true);
  const availability = stringField(data.availability ?? "in_stock", "availability", 20, true);
  if (!AVAILABILITY.has(availability)) throw new HttpsError("invalid-argument", "Availability is not supported.");

  let productId = data.productId;
  let productRef: DocumentReference | undefined;
  let productData: Record<string, unknown> | undefined;
  let mediaRef: DocumentReference | undefined;
  let productImage = "";
  if (data.imageAssetId != null) {
    if (productId != null || typeof data.imageAssetId !== "string" || !/^[A-Za-z0-9_-]{1,100}$/.test(data.imageAssetId)) {
      throw new HttpsError("invalid-argument", "A new product image requires a new product listing.");
    }
    mediaRef = db.collection("mediaAssets").doc(`${uid}_${data.imageAssetId}`);
    const media = await mediaRef.get();
    const mediaData = media.data();
    if (!media.exists || mediaData?.uid !== uid || mediaData.status !== "ready" ||
        typeof mediaData.downloadUrl !== "string" || typeof mediaData.publicPath !== "string" ||
        !mediaData.publicPath.startsWith(`products/public/${uid}/`)) {
      throw new HttpsError("failed-precondition", "The product image has not finished processing.");
    }
    productImage = mediaData.downloadUrl;
  }
  if (productId != null) {
    if (typeof productId !== "number" || !Number.isSafeInteger(productId) || productId <= 0) {
      throw new HttpsError("invalid-argument", "productId must be a valid catalog ID.");
    }
    const products = await db.collection("products").where("numericId", "==", productId).limit(1).get();
    if (products.empty) throw new HttpsError("not-found", "Product was not found.");
  } else {
    const name = stringField(data.name, "name", 80, true);
    const category = stringField(data.category ?? "Groceries", "category", 40, true);
    productId = await nextId("products", "productIds");
    productRef = db.collection("products").doc();
    const brand = stringField(data.brand, "brand", 80);
    const aliases = [name];
    const attributes = data.attributes != null && typeof data.attributes === "object" && !Array.isArray(data.attributes)
      ? data.attributes as Record<string, unknown>
      : {};
    productData = {
      numericId: productId,
      name,
      category,
      brand,
      package_size: stringField(data.packageSize, "packageSize", 60),
      aliases,
      barcode: stringField(data.barcode, "barcode", 80),
      image: productImage,
      attributes,
      searchPrefixes: searchPrefixes([
        name,
        brand,
        category,
        ...Object.values(attributes).map((value) => String(value)),
        ...aliases,
      ]),
      createdByUid: uid,
    };
  }

  const listingId = await nextId("listings", "listingIds");
  const listingRef = db.collection("listings").doc();
  const now = Timestamp.now().toDate().toISOString();
  const movementRef = db.collection("stockMovements").doc();
  await db.runTransaction(async (transaction) => {
    if (mediaRef) {
      const media = await transaction.get(mediaRef);
      const mediaData = media.data();
      if (!media.exists || mediaData?.uid !== uid || mediaData.status !== "ready" ||
          mediaData.linkedProductId != null || mediaData.downloadUrl !== productImage) {
        throw new HttpsError("failed-precondition", "This product image has already been used or is no longer available.");
      }
      transaction.update(mediaRef, { linkedProductId: productId, linkedAt: now, updatedAt: Timestamp.now() });
    }
    if (productRef) transaction.create(productRef, productData!);
    transaction.create(listingRef, {
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
      ownerUid: uid,
    });
    transaction.create(movementRef, {
      listingId,
      kind: "add",
      quantity_delta: quantity,
      note: "Owner confirmed listing",
      created_at: now,
      ownerUid: uid,
    });
  });
  return { id: listingId, productId };
});

export const updateStoreListing = onCall(CALLABLE_OPTIONS, async (request) => {
  const uid = uidFor(request);
  const data = objectData(request.data, "Listing update");
  const listingId = amount(data?.listingId, "listingId", 1, Number.MAX_SAFE_INTEGER);
  if (!Number.isSafeInteger(listingId)) throw new HttpsError("invalid-argument", "listingId must be an integer.");
  const listingQuery = await db.collection("listings").where("numericId", "==", listingId).limit(1).get();
  if (listingQuery.empty) throw new HttpsError("not-found", "Listing was not found.");
  const listingRef = listingQuery.docs[0].ref;
  const existing = listingQuery.docs[0].data();
  const storeId = Number(existing.storeId);
  await storeAndGrant(uid, storeId);

  const quantity = data.quantity == null ? Number(existing.quantity ?? 0) : amount(data.quantity, "quantity", 0, 100_000);
  const price = data.price == null ? Number(existing.price ?? 0) : amount(data.price, "price", 0, 1_000_000);
  const availability = data.availability == null
    ? String(existing.availability)
    : stringField(data.availability, "availability", 20, true);
  const status = data.status == null ? String(existing.status) : stringField(data.status, "status", 20, true);
  if (!AVAILABILITY.has(availability) || !LISTING_STATUS.has(status)) {
    throw new HttpsError("invalid-argument", "Availability or listing status is not supported.");
  }
  const unit = data.unit == null ? String(existing.unit) : stringField(data.unit, "unit", 40, true);
  const now = Timestamp.now().toDate().toISOString();
  const batch = db.batch();
  batch.update(listingRef, {
    price,
    quantity,
    unit,
    availability,
    status,
    last_confirmed_at: now,
  });
  const delta = quantity - Number(existing.quantity ?? 0);
  if (delta !== 0 || status !== existing.status) {
    batch.create(db.collection("stockMovements").doc(), {
      listingId,
      kind: status === "archived" ? "archive" : "adjust",
      quantity_delta: delta,
      note: status === "unavailable" ? "Marked unavailable" : "Stock update",
      created_at: now,
      ownerUid: uid,
    });
  }
  await batch.commit();
  return { ok: true, id: listingId };
});

export const archiveStoreListing = onCall(CALLABLE_OPTIONS, async (request) => {
  const uid = uidFor(request);
  const listingId = amount(request.data?.listingId, "listingId", 1, Number.MAX_SAFE_INTEGER);
  if (!Number.isSafeInteger(listingId)) throw new HttpsError("invalid-argument", "listingId must be an integer.");
  const results = await db.collection("listings").where("numericId", "==", listingId).limit(1).get();
  if (results.empty) throw new HttpsError("not-found", "Listing was not found.");
  const listing = results.docs[0].data();
  await storeAndGrant(uid, Number(listing.storeId));
  if (listing.status === "archived") return { ok: true, id: listingId };
  const now = Timestamp.now().toDate().toISOString();
  const batch = db.batch();
  batch.update(results.docs[0].ref, { status: "archived", last_confirmed_at: now });
  batch.create(db.collection("stockMovements").doc(), {
    listingId,
    kind: "archive",
    quantity_delta: 0,
    note: "Listing archived",
    created_at: now,
    ownerUid: uid,
  });
  await batch.commit();
  return { ok: true, id: listingId };
});

export const listStoreListingMovements = onCall(CALLABLE_OPTIONS, async (request) => {
  const uid = uidFor(request);
  const data = objectData(request.data, "Movement history request");
  const listingId = amount(data?.listingId, "listingId", 1, Number.MAX_SAFE_INTEGER);
  if (!Number.isSafeInteger(listingId)) throw new HttpsError("invalid-argument", "listingId must be an integer.");
  const listings = await db.collection("listings").where("numericId", "==", listingId).limit(1).get();
  if (listings.empty) throw new HttpsError("not-found", "Listing was not found.");
  await storeAndGrant(uid, Number(listings.docs[0].data().storeId));
  const movements = await db.collection("stockMovements")
    .where("listingId", "==", listingId)
    .orderBy("created_at", "desc")
    .limit(100)
    .get();
  return {
    movements: movements.docs.map((doc) => {
      const movement = doc.data();
      return {
        kind: movement.kind,
        quantity_delta: movement.quantity_delta,
        note: movement.note,
        created_at: movement.created_at,
      };
    }),
  };
});
