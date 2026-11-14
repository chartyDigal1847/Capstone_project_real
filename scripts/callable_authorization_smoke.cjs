const assert = require("node:assert/strict");
const path = require("node:path");
const { createRequire } = require("node:module");
const requireFunctions = createRequire(path.resolve(__dirname, "../functions/package.json"));
const { initializeApp } = requireFunctions("firebase-admin/app");
const { getFirestore } = requireFunctions("firebase-admin/firestore");

const projectId = process.env.GCLOUD_PROJECT || "demo-localspot";
const authHost = "http://127.0.0.1:9099";
const functionsBase = `http://127.0.0.1:5001/${projectId}/asia-southeast1`;
const firestoreHost = process.env.FIRESTORE_EMULATOR_HOST || "127.0.0.1:8080";
process.env.FIRESTORE_EMULATOR_HOST = firestoreHost;
const adminApp = initializeApp({ projectId }, "callable-authorization-smoke");
const db = getFirestore(adminApp);

async function jsonRequest(url, options = {}) {
  const response = await fetch(url, options);
  const text = await response.text();
  let body;
  try {
    body = text ? JSON.parse(text) : null;
  } catch {
    body = text;
  }
  return { response, body };
}

async function createUser() {
  const email = `callable-${Date.now()}-${Math.random().toString(16).slice(2)}@example.test`;
  const result = await jsonRequest(`${authHost}/identitytoolkit.googleapis.com/v1/accounts:signUp?key=fake-api-key`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ email, password: "LocalSpot123!", returnSecureToken: true }),
  });
  assert.equal(result.response.status, 200, `Auth signup failed: ${JSON.stringify(result.body)}`);
  return result.body;
}

async function callable(name, token, data) {
  const headers = { "content-type": "application/json" };
  if (token) headers.authorization = `Bearer ${token}`;
  return jsonRequest(`${functionsBase}/${name}`, {
    method: "POST",
    headers,
    body: JSON.stringify({ data }),
  });
}

function assertCallableError(result, status) {
  const httpStatus = {
    INVALID_ARGUMENT: 400,
    PERMISSION_DENIED: 403,
    RESOURCE_EXHAUSTED: 429,
  }[status];
  assert.equal(result.response.status, httpStatus, `Expected ${status}; got ${JSON.stringify(result.body)}`);
  assert.equal(result.body?.error?.status, status, `Unexpected callable error: ${JSON.stringify(result.body)}`);
}

async function waitForProfile(uid) {
  for (let attempt = 0; attempt < 30; attempt++) {
    const profile = await db.collection("users").doc(uid).get();
    if (profile.exists) return profile;
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  throw new Error(`Auth trigger did not create profile for ${uid}`);
}

async function deleteWhere(collection, field, value) {
  const matches = await db.collection(collection).where(field, "==", value).get();
  if (matches.empty) return;
  const batch = db.batch();
  for (const doc of matches.docs) batch.delete(doc.ref);
  await batch.commit();
}

async function cleanup(users, storeId, tourId, listingId, productId) {
  if (listingId != null) {
    await deleteWhere("stockMovements", "listingId", listingId);
    await deleteWhere("listings", "numericId", listingId);
  }
  if (productId != null) await deleteWhere("products", "numericId", productId);
  if (tourId != null) await deleteWhere("tours", "numericId", tourId);
  if (storeId != null) {
    await deleteWhere("auditLogs", "storeId", storeId);
    await deleteWhere("stores", "numericId", storeId);
  }
  for (const user of users) {
    if (!user) continue;
    await deleteWhere("feedback", "uid", user.localId);
    await deleteWhere("reports", "uid", user.localId);
    await deleteWhere("systemRateLimits", "uid", user.localId);
    await db.collection("users").doc(user.localId).delete().catch(() => {});
    await db.collection("systemRateLimits").doc(`${user.localId}_storeApplication`).delete().catch(() => {});
    await jsonRequest(`${authHost}/identitytoolkit.googleapis.com/v1/accounts:delete?key=fake-api-key`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ idToken: user.idToken }),
    }).catch(() => {});
  }
}

async function main() {
  let owner;
  let other;
  let storeId;
  let tourId;
  let listingId;
  let productId;
  try {
  owner = await createUser();
  await waitForProfile(owner.localId);
  const feedback = await callable("submitUserFeedback", owner.idToken, {
    topic: "Search",
    body: "The result list loaded slowly.",
  });
  assert.equal(feedback.response.status, 200, `Feedback submission failed: ${JSON.stringify(feedback.body)}`);
  assert.ok(Number.isSafeInteger(feedback.body?.result?.id));
  assertCallableError(await callable("submitUserFeedback", owner.idToken, {
    topic: " ",
    body: "Invalid empty topic",
  }), "INVALID_ARGUMENT");
  for (let index = 1; index < 5; index++) {
    const accepted = await callable("submitUserFeedback", owner.idToken, {
      topic: `Topic ${index}`,
      body: "Rate limit coverage",
    });
    assert.equal(accepted.response.status, 200, `Feedback request ${index} failed: ${JSON.stringify(accepted.body)}`);
  }
  assertCallableError(await callable("submitUserFeedback", owner.idToken, {
    topic: "Too many",
    body: "This request must be throttled",
  }), "RESOURCE_EXHAUSTED");
  const report = await callable("submitUserReport", owner.idToken, {
    target: "listing:123",
    reason: "The price may be out of date.",
  });
  assert.equal(report.response.status, 200, `Report submission failed: ${JSON.stringify(report.body)}`);
  assert.ok(Number.isSafeInteger(report.body?.result?.id));

  const submission = await callable("submitStoreApplication", owner.idToken, {
    name: "Callable smoke store",
    type: "hardware",
    lat: 14.6195,
    lng: 121.0568,
    barangay: "Project 4",
    city: "Quezon City",
    address: "Test address",
    landmark: "Test landmark",
    schedule: "Daily",
    is_mobile: false,
    verification_note: "",
  });
  assert.equal(submission.response.status, 200, `Store submission failed: ${JSON.stringify(submission.body)}`);
  storeId = submission.body?.result?.id;
  assert.ok(Number.isSafeInteger(storeId), `Missing store ID: ${JSON.stringify(submission.body)}`);

  assertCallableError(
    await callable("approveStoreApplication", owner.idToken, { storeId }),
    "PERMISSION_DENIED",
  );

  const storeQuery = await db.collection("stores").where("numericId", "==", storeId).limit(1).get();
  assert.equal(storeQuery.size, 1);
  await storeQuery.docs[0].ref.update({ status: "approved" });

  const tour = await callable("manageStoreTour", owner.idToken, {
    action: "create",
    storeId,
    title: "Callable smoke tour",
  });
  assert.equal(tour.response.status, 200, `Owner tour creation failed: ${JSON.stringify(tour.body)}`);
  tourId = tour.body?.result?.id;
  assert.ok(Number.isSafeInteger(tourId), `Missing tour ID: ${JSON.stringify(tour.body)}`);

  const listing = await callable("createStoreListing", owner.idToken, {
    storeId,
    name: "Smoke hammer",
    category: "Hardware",
    price: 150,
    unit: "piece",
    quantity: 3,
    availability: "in_stock",
  });
  assert.equal(listing.response.status, 200, `Owner listing create failed: ${JSON.stringify(listing.body)}`);
  listingId = listing.body?.result?.id;
  assert.ok(Number.isSafeInteger(listingId), `Missing listing ID: ${JSON.stringify(listing.body)}`);
  productId = listing.body?.result?.productId;

  other = await createUser();
  await waitForProfile(other.localId);
  assertCallableError(
    await callable("manageStoreTour", other.idToken, {
      action: "connect",
      tourId,
      fromNodeId: 1,
      toNodeId: 2,
    }),
    "PERMISSION_DENIED",
  );
  assertCallableError(
    await callable("updateStoreListing", other.idToken, { listingId, price: 1 }),
    "PERMISSION_DENIED",
  );
  console.log("Callable authorization smoke checks passed (customer cannot approve or edit another store listing; owner can create a listing)");
  } finally {
    await cleanup([owner, other], storeId, tourId, listingId, productId);
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
}).finally(() => db.terminate());
