const assert = require("node:assert/strict");
const { randomUUID } = require("node:crypto");
const path = require("node:path");
const { createRequire } = require("node:module");
const requireFunctions = createRequire(path.resolve(__dirname, "../functions/package.json"));
const { initializeApp } = requireFunctions("firebase-admin/app");
const { getFirestore, Timestamp } = requireFunctions("firebase-admin/firestore");

const projectId = process.env.GCLOUD_PROJECT || "demo-localspot";
const authHost = "http://127.0.0.1:9099";
const firestoreHost = process.env.FIRESTORE_EMULATOR_HOST || "127.0.0.1:8080";
const firestoreBase = `http://${firestoreHost}/v1/projects/${projectId}/databases/(default)/documents`;
process.env.FIRESTORE_EMULATOR_HOST = firestoreHost;
const app = initializeApp({ projectId }, "firestore-access-smoke");
const db = getFirestore(app);

async function jsonRequest(url, options = {}) {
  const response = await fetch(url, options);
  const text = await response.text();
  let body;
  try { body = text ? JSON.parse(text) : null; } catch { body = text; }
  return { response, body };
}

async function signup() {
  const email = `access-${randomUUID()}@example.test`;
  const result = await jsonRequest(`${authHost}/identitytoolkit.googleapis.com/v1/accounts:signUp?key=fake-api-key`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ email, password: "LocalSpot123!", returnSecureToken: true }),
  });
  assert.equal(result.response.status, 200, `Auth signup failed: ${JSON.stringify(result.body)}`);
  for (let attempt = 0; attempt < 30; attempt++) {
    const profile = await db.collection("users").doc(result.body.localId).get();
    if (profile.exists) return { ...result.body, profile: profile.data() };
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  throw new Error("Auth profile trigger did not create a profile.");
}

async function read(path, token) {
  const headers = token ? { authorization: `Bearer ${token}` } : {};
  return jsonRequest(`${firestoreBase}/${path}`, { headers });
}

async function runQuery(collection, where, token) {
  return runStructuredQuery(collection, where ? { where } : {}, token);
}

async function runStructuredQuery(collection, structuredQuery, token) {
  const headers = { "content-type": "application/json" };
  if (token) headers.authorization = `Bearer ${token}`;
  return jsonRequest(`${firestoreBase}:runQuery`, {
    method: "POST",
    headers,
    body: JSON.stringify({
      structuredQuery: {
        from: [{ collectionId: collection }],
        ...structuredQuery,
      },
    }),
  });
}

function equalFilter(fieldPath, value) {
  return { fieldFilter: { field: { fieldPath }, op: "EQUAL", value: firestoreValue(value) } };
}

async function write(path, token, fields, method = "POST") {
  const headers = { "content-type": "application/json", authorization: `Bearer ${token}` };
  const url = method === "POST"
    ? `${firestoreBase}/${path.split("/")[0]}?documentId=${encodeURIComponent(path.split("/")[1])}`
    : `${firestoreBase}/${path}`;
  return jsonRequest(url, { method, headers, body: JSON.stringify({ fields }) });
}

function firestoreValue(value) {
  if (typeof value === "string") return { stringValue: value };
  if (typeof value === "number") return { integerValue: String(value) };
  if (typeof value === "boolean") return { booleanValue: value };
  return { nullValue: null };
}

function encodeGeohash(latitude, longitude, precision = 4) {
  const alphabet = "0123456789bcdefghjkmnpqrstuvwxyz";
  let south = -90;
  let north = 90;
  let west = -180;
  let east = 180;
  let even = true;
  let bits = 0;
  let value = 0;
  let hash = "";
  while (hash.length < precision) {
    const midpoint = even ? (west + east) / 2 : (south + north) / 2;
    const coordinate = even ? longitude : latitude;
    const upper = coordinate >= midpoint;
    value = (value << 1) | (upper ? 1 : 0);
    if (even) upper ? west = midpoint : east = midpoint;
    else upper ? south = midpoint : north = midpoint;
    even = !even;
    bits++;
    if (bits === 5) {
      hash += alphabet[value];
      bits = 0;
      value = 0;
    }
  }
  return hash;
}

function geohashRangeQuery(status, prefix) {
  return {
    where: {
      compositeFilter: {
        op: "AND",
        filters: [
          equalFilter("status", status),
          {
            fieldFilter: {
              field: { fieldPath: "geohash" },
              op: "GREATER_THAN_OR_EQUAL",
              value: firestoreValue(prefix),
            },
          },
          {
            fieldFilter: {
              field: { fieldPath: "geohash" },
              op: "LESS_THAN",
              value: firestoreValue(`${prefix}~`),
            },
          },
        ],
      },
    },
    orderBy: [{ field: { fieldPath: "geohash" }, direction: "ASCENDING" }],
    limit: 251,
  };
}

function resultDocumentIds(result) {
  assert.equal(result.response.status, 200, `Geohash query failed: ${JSON.stringify(result.body)}`);
  return (result.body || []).map((row) => row.document?.name?.split("/").at(-1)).filter(Boolean);
}

function fields(value) {
  return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, firestoreValue(item)]));
}

function expectStatus(result, status, context) {
  assert.equal(result.response.status, status, `${context}: expected ${status}, got ${result.response.status}: ${JSON.stringify(result.body)}`);
}

async function main() {
  const owner = await signup();
  const other = await signup();
  const suffix = randomUUID().replaceAll("-", "");
  const storeId = Number.parseInt(suffix.slice(0, 7), 16);
  const pendingStore = `pending-${suffix}`;
  const approvedStore = `approved-${suffix}`;
  const pendingPromotion = `pending-${suffix}`;
  const approvedPromotion = `approved-${suffix}`;
  const activeSession = `active-${suffix}`;
  const endedSession = `ended-${suffix}`;
  const expiredSession = `expired-${suffix}`;
  const draftTour = `draft-${suffix}`;
  const prefixProduct = `prefix-${suffix}`;
  const validFavorite = `favorite-valid-${suffix}`;
  const invalidFavoriteType = `favorite-type-${suffix}`;
  const invalidFavoriteId = `favorite-id-${suffix}`;
  const feedbackWithoutArea = `feedback-no-area-${suffix}`;
  const reportValid = `report-valid-${suffix}`;
  const feedbackBadArea = `report-bad-area-${suffix}`;
  const geoStore = `geo-approved-${suffix}`;
  const geoListing = `geo-active-${suffix}`;
  const inactiveGeoListing = `geo-inactive-${suffix}`;
  const geoPrefix = encodeGeohash(14.5995, 121.0364);
  const stores = db.collection("stores");
  const promotions = db.collection("promotions");
  const sessions = db.collection("vendorSessions");
  const tours = db.collection("tours");
  const products = db.collection("products");
  const metadata = db.collection("systemMetadata").doc("searchPrefixIndex");

  try {
    await db.collection("users").doc(owner.localId).update({
      role: "owner",
      ownedStoreIds: [storeId],
    });
    await Promise.all([
      stores.doc(pendingStore).set({ numericId: storeId, ownerUid: owner.localId, status: "pending" }),
      stores.doc(approvedStore).set({ numericId: storeId + 1, ownerUid: owner.localId, status: "approved" }),
      stores.doc(geoStore).set({ numericId: storeId + 2, ownerUid: owner.localId, status: "approved", lat: 14.5995, lng: 121.0364, geohash: geoPrefix }),
      promotions.doc(pendingPromotion).set({ numericId: storeId, ownerUid: owner.localId, status: "pending" }),
      promotions.doc(approvedPromotion).set({ numericId: storeId + 1, ownerUid: owner.localId, status: "approved" }),
      sessions.doc(activeSession).set({ startedByUid: owner.localId, ended_at: null, expiresAt: Timestamp.fromMillis(Date.now() + 60_000) }),
      sessions.doc(endedSession).set({ startedByUid: owner.localId, ended_at: new Date().toISOString(), expiresAt: Timestamp.fromMillis(Date.now() + 60_000) }),
      sessions.doc(expiredSession).set({ startedByUid: owner.localId, ended_at: null, expiresAt: Timestamp.fromMillis(Date.now() - 60_000) }),
      tours.doc(draftTour).set({ numericId: storeId, storeId, ownerUid: owner.localId, status: "draft", nodes: [] }),
      products.doc(prefixProduct).set({ numericId: storeId, name: "Canned sardines", searchPrefixes: ["canned", "canned sardines", "sardines"] }),
      db.collection("listings").doc(geoListing).set({ numericId: storeId + 2, storeId: storeId + 2, productId: storeId, status: "active", lat: 14.5995, lng: 121.0364, geohash: geoPrefix }),
      db.collection("listings").doc(inactiveGeoListing).set({ numericId: storeId + 3, storeId: storeId + 2, productId: storeId, status: "archived", lat: 14.5995, lng: 121.0364, geohash: geoPrefix }),
      metadata.set({ ready: true }),
    ]);

    expectStatus(await read(`stores/${approvedStore}`), 200, "Public approved store");
    expectStatus(await read(`stores/${pendingStore}`), 403, "Anonymous pending store");
    expectStatus(await read(`stores/${pendingStore}`, owner.idToken), 200, "Owner pending store");
    expectStatus(await read(`stores/${pendingStore}`, other.idToken), 403, "Other user pending store");
    expectStatus(await runQuery("stores", equalFilter("status", "approved")), 200, "Public approved-store query");
    expectStatus(await runQuery("stores", null), 403, "Unfiltered public store query");
    expectStatus(await runQuery("stores", equalFilter("ownerUid", owner.localId), owner.idToken), 200, "Owner application query");
    expectStatus(await read(`promotions/${approvedPromotion}`), 200, "Public approved promotion");
    expectStatus(await read(`promotions/${pendingPromotion}`), 403, "Anonymous pending promotion");
    expectStatus(await read(`promotions/${pendingPromotion}`, owner.idToken), 200, "Owner pending promotion");
    expectStatus(await runQuery("promotions", equalFilter("status", "approved")), 200, "Public approved-promotion query");
    expectStatus(await runQuery("promotions", null), 403, "Unfiltered public promotion query");
    const activeSessionQuery = {
      compositeFilter: {
        op: "AND",
        filters: [
          equalFilter("ended_at", null),
          { fieldFilter: { field: { fieldPath: "expiresAt" }, op: "GREATER_THAN", value: { timestampValue: new Date().toISOString() } } },
        ],
      },
    };
    expectStatus(await runQuery("vendorSessions", activeSessionQuery), 403, "Direct active-session query denied");
    expectStatus(await runQuery("vendorSessions", null), 403, "Unfiltered public session query");
    expectStatus(await read("systemMetadata/searchPrefixIndex"), 200, "Public search-index readiness");
    expectStatus(await runQuery("products", {
      fieldFilter: {
        field: { fieldPath: "searchPrefixes" },
        op: "ARRAY_CONTAINS_ANY",
        value: { arrayValue: { values: [{ stringValue: "sardines" }] } },
      },
    }), 200, "Indexed product-prefix query");
    const storeRange = await runStructuredQuery("stores", geohashRangeQuery("approved", geoPrefix));
    assert.deepEqual(resultDocumentIds(storeRange), [geoStore], "Approved store geohash range should return only the seeded location");
    const listingRange = await runStructuredQuery("listings", geohashRangeQuery("active", geoPrefix));
    assert.deepEqual(resultDocumentIds(listingRange), [geoListing], "Active listing geohash range should exclude archived listings");
    expectStatus(await read(`vendorSessions/${activeSession}`), 200, "Public active vendor location");
    expectStatus(await read(`vendorSessions/${endedSession}`), 403, "Ended vendor location");
    expectStatus(await read(`vendorSessions/${expiredSession}`), 403, "Expired vendor location");
    expectStatus(await read(`tours/${draftTour}`, owner.idToken), 200, "Owner draft tour");
    expectStatus(await read(`tours/${draftTour}`, other.idToken), 403, "Other user's draft tour");

    expectStatus(await write(`tours/${draftTour}`, owner.idToken, fields({ status: "published" }), "PATCH"), 403, "Direct tour publication");
    expectStatus(await write(`stores/${pendingStore}`, owner.idToken, fields({ status: "approved" }), "PATCH"), 403, "Direct store approval");
    expectStatus(await write(`promotions/${pendingPromotion}`, owner.idToken, fields({ status: "approved" }), "PATCH"), 403, "Direct promotion approval");
    expectStatus(await write("systemMetadata/searchPrefixIndex", owner.idToken, fields({ ready: false }), "PATCH"), 403, "Client search-index switch write");

    const userId = owner.profile.numericId;
    expectStatus(await write(`feedback/forged-${suffix}`, owner.idToken, fields({
      numericId: storeId, userId: other.profile.numericId, uid: owner.localId,
      topic: "Other user", body: "Spoofed attribution", area: "Test",
    })), 403, "Forged feedback attribution");
    expectStatus(await write(`feedback/valid-${suffix}`, owner.idToken, fields({
      numericId: storeId, userId, uid: owner.localId,
      topic: "Access test", body: "Valid feedback", area: "Test",
    })), 403, "Direct feedback submission is denied");
    expectStatus(await write(`feedback/${feedbackWithoutArea}`, owner.idToken, fields({
      numericId: storeId + 5, userId, uid: owner.localId,
      topic: "No-area test", body: "Feedback may omit its optional area",
    })), 403, "Direct feedback without optional area is denied");
    expectStatus(await write(`feedback/${feedbackBadArea}`, owner.idToken, fields({
      numericId: storeId + 6, userId, uid: owner.localId,
      topic: "Bad area", body: "Invalid area should be rejected", area: null,
    })), 403, "Invalid optional feedback area");
    expectStatus(await write(`favorites/${validFavorite}`, owner.idToken, fields({
      uid: owner.localId, favoritable_type: "store", favoritable_id: storeId,
    })), 200, "Valid favorite creation");
    expectStatus(await read(`favorites/${validFavorite}`, owner.idToken), 200, "Owner reads own favorite");
    expectStatus(await read(`favorites/${validFavorite}`, other.idToken), 403, "Other user cannot read favorite");
    expectStatus(await write(`favorites/${invalidFavoriteType}`, owner.idToken, fields({
      uid: owner.localId, favoritable_type: "tour", favoritable_id: storeId,
    })), 403, "Unsupported favorite target type");
    expectStatus(await write(`favorites/${invalidFavoriteId}`, owner.idToken, fields({
      uid: owner.localId, favoritable_type: "product", favoritable_id: -1,
    })), 403, "Non-positive favorite target ID");
    expectStatus(await write(`reports/forged-${suffix}`, owner.idToken, fields({
      numericId: storeId, userId: other.profile.numericId, uid: owner.localId,
      target: "listing", reason: "Spoofed attribution", resolved: false,
    })), 403, "Forged report attribution");
    expectStatus(await write(`reports/${reportValid}`, owner.idToken, fields({
      numericId: storeId + 7, userId, uid: owner.localId,
      target: "listing", reason: "Valid report", resolved: false,
    })), 403, "Direct report submission is denied");
    expectStatus(await read(`reports/${reportValid}`, owner.idToken), 403, "Reporter cannot read moderation records directly");
    expectStatus(await write(`reports/${reportValid}`, owner.idToken, fields({ resolved: true }), "PATCH"), 403, "Reporter cannot resolve report");
    console.log("Firestore access smoke checks passed (public/private access, status/geohash ranges, active/expired locations and protected writes)");
  } finally {
    await Promise.all([
      stores.doc(pendingStore).delete(), stores.doc(approvedStore).delete(),
      stores.doc(geoStore).delete(),
      promotions.doc(pendingPromotion).delete(), promotions.doc(approvedPromotion).delete(),
      sessions.doc(activeSession).delete(), sessions.doc(endedSession).delete(), sessions.doc(expiredSession).delete(),
      tours.doc(draftTour).delete(),
      products.doc(prefixProduct).delete(),
      db.collection("listings").doc(geoListing).delete(),
      db.collection("listings").doc(inactiveGeoListing).delete(),
      metadata.delete(),
      db.collection("feedback").doc(`forged-${suffix}`).delete(),
      db.collection("feedback").doc(`valid-${suffix}`).delete(),
      db.collection("feedback").doc(feedbackWithoutArea).delete(),
      db.collection("feedback").doc(feedbackBadArea).delete(),
      db.collection("reports").doc(`forged-${suffix}`).delete(),
      db.collection("reports").doc(reportValid).delete(),
      db.collection("favorites").doc(validFavorite).delete(),
      db.collection("favorites").doc(invalidFavoriteType).delete(),
      db.collection("favorites").doc(invalidFavoriteId).delete(),
    ]);
    await db.terminate();
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});

