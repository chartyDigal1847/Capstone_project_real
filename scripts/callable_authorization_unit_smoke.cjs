const assert = require("node:assert/strict");
const path = require("node:path");
const { createRequire } = require("node:module");

const projectId = process.env.GCLOUD_PROJECT || "demo-localspot";
if (!projectId.startsWith("demo-")) {
  throw new Error(`Callable authorization smoke must use a demo project; received ${projectId}`);
}
process.env.FIRESTORE_EMULATOR_HOST ||= "127.0.0.1:8080";
process.env.FIREBASE_AUTH_EMULATOR_HOST ||= "127.0.0.1:9099";
process.env.STORAGE_EMULATOR_HOST ||= "127.0.0.1:9199";
process.env.FIREBASE_STORAGE_EMULATOR_HOST ||= "127.0.0.1:9199";
process.env.FIREBASE_CONFIG = JSON.stringify({ projectId, storageBucket: `${projectId}.appspot.com` });
process.env.GCLOUD_PROJECT = projectId;
const requireFunctions = createRequire(path.resolve(__dirname, "../functions/package.json"));
const { initializeApp } = requireFunctions("firebase-admin/app");
const { getAuth } = requireFunctions("firebase-admin/auth");
const { getFirestore, Timestamp } = requireFunctions("firebase-admin/firestore");
const { getStorage } = requireFunctions("firebase-admin/storage");
initializeApp({ projectId, storageBucket: `${projectId}.appspot.com` });
const auth = getAuth();
const db = getFirestore();
const functions = require("../functions/lib");
let temporaryAuthUid;
const {
  approveStoreApplication,
  archiveStoreListing,
  createStoreListing,
  createStorePromotion,
  deleteUserAccount,
  listStoreListingMovements,
  listStoreMemberships,
  listActiveVendorLocations,
  manageStoreMembership,
  resolveReport,
  reviewStoreApplication,
  reviewStorePromotion,
  startVendorLocationSession,
  stopVendorLocationSession,
  submitStoreApplication,
  updateStoreListing,
  updateVendorLocationSession,
} = functions;

function caller(uid, data) {
  return { auth: { uid, token: {} }, data };
}

async function expectCode(promise, code) {
  try {
    await promise;
  } catch (error) {
    assert.equal(error.code, code, `Unexpected callable error: ${error.message}`);
    return;
  }
  assert.fail(`Expected callable to fail with ${code}`);
}

async function main() {
  const protectedFunctions = [
    approveStoreApplication,
    archiveStoreListing,
    createStoreListing,
    createStorePromotion,
    manageStoreMembership,
    resolveReport,
    reviewStoreApplication,
    reviewStorePromotion,
    startVendorLocationSession,
    stopVendorLocationSession,
    submitStoreApplication,
    updateStoreListing,
    updateVendorLocationSession,
  ];
  for (const fn of protectedFunctions) {
    await expectCode(fn.run({ auth: null, data: {} }), "unauthenticated");
  }

  const ownerUid = `owner-${Date.now()}`;
  const otherUid = `customer-${Date.now()}`;
  const adminUid = `admin-${Date.now()}`;
  await db.collection("users").doc(ownerUid).set({
    numericId: 10001,
    name: "Smoke owner",
    email: `${ownerUid}@example.test`,
    role: "customer",
    ownedStoreIds: [],
    memberStoreIds: [],
    storeGrants: [],
  });
  await db.collection("users").doc(otherUid).set({
    numericId: 10002,
    name: "Smoke customer",
    email: `${otherUid}@example.test`,
    role: "customer",
    ownedStoreIds: [],
    memberStoreIds: [],
    storeGrants: [],
  });
  await db.collection("users").doc(adminUid).set({
    numericId: 10003,
    name: "Smoke admin",
    email: `${adminUid}@example.test`,
    role: "admin",
    ownedStoreIds: [],
    memberStoreIds: [],
    storeGrants: [],
  });

  const applicationDetails = {
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
  };
  const submission = await submitStoreApplication.run(caller(ownerUid, applicationDetails));
  const storeId = submission.id;
  assert.ok(Number.isSafeInteger(storeId));
  await expectCode(approveStoreApplication.run(caller(ownerUid, { storeId })), "permission-denied");

  const storeQuery = await db.collection("stores").where("numericId", "==", storeId).limit(1).get();
  await storeQuery.docs[0].ref.update({ status: "approved" });

  const staffEmail = `smoke-staff-${Date.now()}@example.test`;
  const staffAuth = await auth.createUser({ email: staffEmail, password: "LocalSpot123!" });
  temporaryAuthUid = staffAuth.uid;
  await db.collection("users").doc(staffAuth.uid).set({
    numericId: 10004,
    name: "Smoke staff",
    email: staffEmail,
    role: "customer",
    ownedStoreIds: [],
    memberStoreIds: [],
    storeGrants: [],
  });
  const staffRequest = {
    storeId,
    email: staffEmail,
    action: "set",
    inventory: true,
    promotions: false,
    location: false,
  };
  const foreignStoreId = storeId + 1_000_000;
  await db.collection("stores").doc(`callable-smoke-foreign-${storeId}`).set({
    numericId: foreignStoreId,
    ownerUid: otherUid,
    status: "approved",
  });
  await expectCode(manageStoreMembership.run(caller(otherUid, staffRequest)), "permission-denied");
  await expectCode(manageStoreMembership.run(caller(ownerUid, { ...staffRequest, storeId: foreignStoreId })), "permission-denied");
  await manageStoreMembership.run(caller(ownerUid, staffRequest));
  await expectCode(
    listStoreMemberships.run(caller(otherUid, { storeId })),
    "permission-denied",
  );
  const staffDirectory = await listStoreMemberships.run(caller(ownerUid, { storeId }));
  assert.equal(staffDirectory.members.length, 1);
  assert.equal(staffDirectory.members[0].id, 10004);
  assert.equal(staffDirectory.members[0].name, "Smoke staff");
  assert.equal(staffDirectory.members[0].email, staffEmail);
  assert.deepEqual(staffDirectory.members[0].store_grants, [
    { store_id: storeId, inventory: true, promotions: false, location: false },
  ]);
  const memberRef = db.collection("storeMembers").doc(`${storeId}_${staffAuth.uid}`);
  const membership = await memberRef.get();
  assert.equal(membership.data()?.inventory, true);
  assert.equal(membership.data()?.promotions, false);
  assert.deepEqual((await db.collection("users").doc(staffAuth.uid).get()).data()?.memberStoreIds, [storeId]);
  await manageStoreMembership.run(caller(ownerUid, { ...staffRequest, location: true }));
  const locationGrant = await memberRef.get();
  assert.equal(locationGrant.data()?.location, true);
  const location = { storeId, lat: 14.62, lng: 121.05 };
  const startedSession = await startVendorLocationSession.run(caller(ownerUid, location));
  assert.equal(startedSession.startedByUid, ownerUid);
  assert.equal(startedSession.ownerUid, ownerUid);
  await expectCode(startVendorLocationSession.run(caller(ownerUid, location)), "already-exists");
  await db.collection("vendorSessions").doc(String(storeId)).update({ last_update_at: new Date().toISOString() });
  await expectCode(updateVendorLocationSession.run(caller(ownerUid, { ...location, lat: 14.63 })), "resource-exhausted");
  await expectCode(updateVendorLocationSession.run(caller(staffAuth.uid, { ...location, lat: 14.63 })), "permission-denied");
  await expectCode(stopVendorLocationSession.run(caller(staffAuth.uid, location)), "permission-denied");
  await db.collection("vendorSessions").doc(String(storeId)).update({
    last_update_at: new Date(Date.now() - 16_000).toISOString(),
  });
  await updateVendorLocationSession.run(caller(ownerUid, { ...location, lat: 14.63, lng: 121.06 }));
  const updatedSession = await db.collection("vendorSessions").doc(String(storeId)).get();
  assert.equal(updatedSession.data()?.lat, 14.63);
  assert.equal(updatedSession.data()?.lng, 121.06);
  await stopVendorLocationSession.run(caller(ownerUid, location));
  const stoppedSession = await db.collection("vendorSessions").doc(String(storeId)).get();
  assert.equal(typeof stoppedSession.data()?.ended_at, "string");
  await expectCode(updateVendorLocationSession.run(caller(ownerUid, location)), "failed-precondition");
  const listing = await createStoreListing.run(caller(ownerUid, {
    storeId,
    name: "Smoke hammer",
    category: "Hardware",
    price: 150,
    unit: "piece",
    quantity: 3,
    availability: "in_stock",
  }));
  assert.ok(Number.isSafeInteger(listing.id));
  await expectCode(updateStoreListing.run(caller(otherUid, { listingId: listing.id, price: 1 })), "permission-denied");
  const movements = await listStoreListingMovements.run(caller(ownerUid, { listingId: listing.id }));
  assert.equal(movements.movements.length, 1);
  assert.equal(movements.movements[0].kind, "add");
  await expectCode(
    listStoreListingMovements.run(caller(otherUid, { listingId: listing.id })),
    "permission-denied",
  );
  await updateStoreListing.run(caller(staffAuth.uid, { listingId: listing.id, price: 155, quantity: 4 }));
  const staffListing = await db.collection("listings").where("numericId", "==", listing.id).limit(1).get();
  assert.equal(staffListing.docs[0].data().price, 155);
  assert.equal(staffListing.docs[0].data().quantity, 4);
  const staffMovements = await listStoreListingMovements.run(caller(staffAuth.uid, { listingId: listing.id }));
  assert.equal(staffMovements.movements.length, 2);

  const startsAt = new Date().toISOString();
  const endsAt = new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString();
  await expectCode(createStorePromotion.run(caller(staffAuth.uid, {
    storeId,
    title: "Promotion without grant",
    offer: "Test offer",
    starts_at: startsAt,
    ends_at: endsAt,
  })), "permission-denied");
  await manageStoreMembership.run(caller(ownerUid, { ...staffRequest, action: "remove" }));
  assert.equal((await memberRef.get()).exists, false);
  const removedStaffProfile = await db.collection("users").doc(staffAuth.uid).get();
  assert.deepEqual(removedStaffProfile.data()?.memberStoreIds, []);
  assert.equal(removedStaffProfile.data()?.role, "customer");
  await expectCode(updateStoreListing.run(caller(staffAuth.uid, { listingId: listing.id, price: 160 })), "permission-denied");
  let sponsoredPromotionId;
  for (let index = 0; index < 10; index++) {
    const promotion = await createStorePromotion.run(caller(ownerUid, {
      storeId,
      title: `Smoke promotion ${index + 1}`,
      offer: "Test offer",
      starts_at: startsAt,
      ends_at: endsAt,
      sponsored: index === 0,
    }));
    if (index === 0) sponsoredPromotionId = promotion.id;
  }
  const pendingPromotion = await db.collection("promotions").where("numericId", "==", sponsoredPromotionId).limit(1).get();
  assert.equal(pendingPromotion.docs[0].data().status, "pending");
  assert.equal(pendingPromotion.docs[0].data().sponsored, false);
  assert.equal(pendingPromotion.docs[0].data().sponsoredRequested, true);
  await expectCode(reviewStorePromotion.run(caller(ownerUid, {
    promotionId: sponsoredPromotionId,
    status: "approved",
  })), "permission-denied");
  const approvedPromotion = await reviewStorePromotion.run(caller(adminUid, {
    promotionId: sponsoredPromotionId,
    status: "approved",
  }));
  assert.equal(approvedPromotion.status, "approved");
  const reviewedPromotion = await db.collection("promotions").where("numericId", "==", sponsoredPromotionId).limit(1).get();
  assert.equal(reviewedPromotion.docs[0].data().sponsored, true);
  const promotionAudit = await db.collection("auditLogs")
    .where("promotionId", "==", sponsoredPromotionId)
    .limit(1)
    .get();
  assert.equal(promotionAudit.size, 1);
  assert.equal(promotionAudit.docs[0].data().actorUid, adminUid);
  const reportId = Date.now();
  await db.collection("reports").doc(`callable-smoke-${reportId}`).set({
    numericId: reportId,
    userId: 10002,
    uid: otherUid,
    target: "store",
    reason: "Smoke test report",
    resolved: false,
  });
  await expectCode(resolveReport.run(caller(ownerUid, { reportId })), "permission-denied");
  const resolution = await resolveReport.run(caller(adminUid, { reportId }));
  assert.deepEqual(resolution, { ok: true, reportId });
  const resolvedReport = await db.collection("reports").doc(`callable-smoke-${reportId}`).get();
  assert.equal(resolvedReport.data()?.resolved, true);
  assert.equal(resolvedReport.data()?.resolvedByUid, adminUid);
  assert.ok(Number.isFinite(Date.parse(resolvedReport.data()?.resolvedAt)));
  await resolveReport.run(caller(adminUid, { reportId }));
  const reportAudits = await db.collection("auditLogs").where("reportId", "==", reportId).get();
  assert.equal(reportAudits.size, 1);
  assert.equal(reportAudits.docs[0].data().actorUid, adminUid);
  await expectCode(createStorePromotion.run(caller(ownerUid, {
    storeId,
    title: "Promotion over daily limit",
    offer: "Test offer",
    starts_at: startsAt,
    ends_at: endsAt,
  })), "resource-exhausted");

  const secondSubmission = await submitStoreApplication.run(caller(ownerUid, {
    ...applicationDetails,
    name: "Callable smoke store two",
  }));
  await expectCode(
    submitStoreApplication.run(caller(ownerUid, { ...applicationDetails, name: "Duplicate pending application" })),
    "already-exists",
  );
  const secondStore = await db.collection("stores").where("numericId", "==", secondSubmission.id).limit(1).get();
  await secondStore.docs[0].ref.update({ status: "rejected" });

  const thirdSubmission = await submitStoreApplication.run(caller(ownerUid, {
    ...applicationDetails,
    name: "Callable smoke store three",
  }));
  const thirdStore = await db.collection("stores").where("numericId", "==", thirdSubmission.id).limit(1).get();
  await thirdStore.docs[0].ref.update({ status: "rejected" });
  await expectCode(
    submitStoreApplication.run(caller(ownerUid, { ...applicationDetails, name: "Application over daily limit" })),
    "resource-exhausted",
  );

  const now = Date.now();
  await db.collection("vendorSessions").doc(String(storeId)).set({
    storeId,
    startedByUid: ownerUid,
    ownerUid,
    ended_at: null,
    expiresAt: Timestamp.fromMillis(now + 60_000),
    expires_at: new Date(now + 60_000).toISOString(),
    lat: 14.62,
    lng: 121.05,
  });
  await db.collection("vendorSessions").doc(`ended-${storeId}`).set({
    storeId,
    ended_at: new Date(now).toISOString(),
    expiresAt: Timestamp.fromMillis(now + 60_000),
  });
  await db.collection("vendorSessions").doc(`expired-${storeId}`).set({
    storeId,
    ended_at: null,
    expiresAt: Timestamp.fromMillis(now - 60_000),
  });
  const publicLocations = await listActiveVendorLocations.run({
    auth: null,
    data: {},
  });
  assert.equal(publicLocations.sessions.length, 1);
  assert.equal(publicLocations.sessions[0].storeId, storeId);
  assert.equal("ownerUid" in publicLocations.sessions[0], false);
  assert.equal("startedByUid" in publicLocations.sessions[0], false);

  await expectCode(deleteUserAccount.run({
    auth: { uid: ownerUid, token: { auth_time: Math.floor((Date.now() - 10 * 60_000) / 1000) } },
    data: {},
  }), "failed-precondition");
  const recentAuthTime = Math.floor(Date.now() / 1000);
  await expectCode(deleteUserAccount.run({
    auth: { uid: adminUid, token: { auth_time: recentAuthTime } },
    data: {},
  }), "failed-precondition");
  await expectCode(deleteUserAccount.run({
    auth: { uid: ownerUid, token: { auth_time: recentAuthTime } },
    data: {},
  }), "failed-precondition");

  const staffUid = staffAuth.uid;
  const storage = getStorage().bucket();
  const linkedProductPath = `products/public/${staffUid}/linked.jpg`;
  const unlinkedProductPath = `products/quarantine/${staffUid}/unlinked.jpg`;
  const linkedStorePath = `stores/processed/${staffUid}/store.jpg`;
  const tourOriginalPath = `tours/originals/${staffUid}/tour-1/original.jpg`;
  const orphanPanoramaPath = `tours/originals/${staffUid}/tour-2/rejected.jpg`;
  for (const path of [linkedProductPath, unlinkedProductPath, linkedStorePath, tourOriginalPath, orphanPanoramaPath]) {
    await storage.file(path).save(Buffer.from("smoke image bytes"), {
      resumable: false,
      metadata: { contentType: "image/jpeg" },
    });
  }
  await db.collection("users").doc(staffUid).update({ memberStoreIds: [storeId] });
  for (let offset = 0; offset < 120; offset += 100) {
    const batch = db.batch();
    for (let index = offset; index < Math.min(offset + 100, 120); index++) {
      batch.set(db.collection("tours").doc(`callable-bulk-delete-${staffUid}-${String(index).padStart(3, "0")}`), {
        ownerUid: staffUid,
        numericId: Date.now() + index,
        status: "draft",
        nodes: [],
      });
    }
    await batch.commit();
  }
  await Promise.all([
    db.collection("favorites").doc(`callable-smoke-${staffUid}`).set({ uid: staffUid }),
    db.collection("feedback").doc(`callable-smoke-${staffUid}`).set({ uid: staffUid }),
    db.collection("reports").doc(`callable-smoke-${staffUid}`).set({ uid: staffUid }),
    db.collection("storeMembers").doc(`callable-smoke-${staffUid}`).set({ storeId, userUid: staffUid }),
    db.collection("systemRateLimits").doc(`callable-smoke-${staffUid}`).set({ uid: staffUid }),
    db.collection("stores").doc(`callable-smoke-pending-${staffUid}`).set({ numericId: Date.now(), ownerUid: staffUid, status: "pending" }),
    db.collection("tours").doc(`callable-smoke-${staffUid}`).set({ numericId: Date.now(), ownerUid: staffUid, nodes: [{ original_path: tourOriginalPath }] }),
    db.collection("mediaAssets").doc(`callable-linked-product-${staffUid}`).set({
      uid: staffUid, status: "ready", linkedProductId: 987654, publicPath: linkedProductPath,
    }),
    db.collection("mediaAssets").doc(`callable-unlinked-product-${staffUid}`).set({
      uid: staffUid, status: "failed", quarantinePath: unlinkedProductPath,
    }),
    db.collection("mediaAssets").doc(`callable-linked-store-${staffUid}`).set({
      uid: staffUid, status: "ready", linkedStoreId: 987654, privatePath: linkedStorePath,
    }),
    db.collection("mediaAssets").doc(`callable-failed-panorama-${staffUid}`).set({
      uid: staffUid, status: "failed", mediaType: "panorama", originalPath: orphanPanoramaPath,
    }),
    db.collection("vendorSessions").doc(`callable-delete-${staffUid}`).set({
      startedByUid: staffUid, ended_at: null, lat: 14.61, lng: 121.05,
    }),
    db.collection("auditLogs").doc(`callable-delete-${staffUid}`).set({ action: "smoke.preserved", actorUid: staffUid }),
  ]);

  const deletion = await deleteUserAccount.run({
    auth: { uid: staffUid, token: { auth_time: Math.floor(Date.now() / 1000) } },
    data: {},
  });
  assert.deepEqual(deletion, { ok: true });
  assert.equal((await db.collection("users").doc(staffUid).get()).exists, false);
  for (const collection of ["favorites", "feedback", "reports", "storeMembers", "systemRateLimits", "tours", "stores"]) {
    const remains = await db.collection(collection).where(collection === "storeMembers" ? "userUid" : collection === "tours" || collection === "stores" ? "ownerUid" : "uid", "==", staffUid).get();
    assert.equal(remains.empty, true, `Account deletion left ${collection} data behind`);
  }
  assert.equal((await db.collection("mediaAssets").doc(`callable-linked-product-${staffUid}`).get()).data()?.uid, null);
  assert.equal((await db.collection("mediaAssets").doc(`callable-unlinked-product-${staffUid}`).get()).exists, false);
  assert.equal((await db.collection("mediaAssets").doc(`callable-linked-store-${staffUid}`).get()).exists, false);
  const deletedUserSession = await db.collection("vendorSessions").doc(`callable-delete-${staffUid}`).get();
  assert.equal(deletedUserSession.data()?.lat, null);
  assert.equal(deletedUserSession.data()?.lng, null);
  assert.equal(deletedUserSession.data()?.startedByUid, null);
  assert.equal(typeof deletedUserSession.data()?.ended_at, "string");
  assert.equal((await db.collection("auditLogs").doc(`callable-delete-${staffUid}`).get()).exists, true);
  assert.equal((await storage.file(linkedProductPath).exists())[0], true);
  for (const path of [unlinkedProductPath, linkedStorePath, tourOriginalPath, orphanPanoramaPath]) {
    assert.equal((await storage.file(path).exists())[0], false, `Account deletion retained ${path}`);
  }
  await assert.rejects(auth.getUser(staffUid), (error) => error.code === "auth/user-not-found");
  temporaryAuthUid = undefined;
  console.log("Callable authorization unit smoke checks passed (membership, vendor sessions, report resolution, account deletion, and moderation)");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
}).finally(async () => {
  if (temporaryAuthUid) await auth.deleteUser(temporaryAuthUid).catch(() => {});
  await db.terminate();
});
