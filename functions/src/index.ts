import { createHash } from "node:crypto";
import { db } from "./admin";
import * as logger from "firebase-functions/logger";
import { onUserCreated } from "firebase-functions/v2/identity";
import { enforceCallableAppCheck } from "./callable_options";

const FUNCTION_REGION = "asia-southeast1";

export { approveStoreApplication, listStoreMemberships, manageStoreMembership, reviewStoreApplication, submitStoreApplication, updateStore } from "./stores";
export { archiveStoreListing, createStoreListing, listStoreListingMovements, updateStoreListing } from "./listings";
export { createStorePromotion, reviewStorePromotion } from "./promotions";
export { listActiveVendorLocations, startVendorLocationSession, stopVendorLocationSession, updateVendorLocationSession } from "./vendor_locations";
export { deleteUserAccount } from "./account";
export { processUploadedMedia, validatePanoramaUpload } from "./media_uploads";
export { manageStoreTour } from "./tours";
export { cleanupExpiredMediaAssets } from "./cleanup";
export { submitUserFeedback, submitUserReport } from "./user_submissions";

import { Timestamp } from "firebase-admin/firestore";
import { HttpsError, onCall } from "firebase-functions/v2/https";

export const resolveReport = onCall({ region: FUNCTION_REGION, enforceAppCheck: enforceCallableAppCheck }, async (request) => {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Sign in to continue.");
  const reportId = request.data?.reportId;
  if (typeof reportId !== "number" || !Number.isSafeInteger(reportId) || reportId <= 0) {
    throw new HttpsError("invalid-argument", "A valid report ID is required.");
  }
  const admin = await db.collection("users").doc(uid).get();
  if (!admin.exists || admin.data()?.role !== "admin") {
    throw new HttpsError("permission-denied", "Administrator access is required.");
  }
  const matches = await db.collection("reports").where("numericId", "==", reportId).limit(1).get();
  if (matches.empty) throw new HttpsError("not-found", "Report was not found.");
  const reportRef = matches.docs[0].ref;
  await db.runTransaction(async (transaction) => {
    const report = await transaction.get(reportRef);
    if (!report.exists) throw new HttpsError("not-found", "Report was not found.");
    if (report.data()?.resolved === true) return;
    transaction.update(reportRef, { resolved: true, resolvedByUid: uid, resolvedAt: Timestamp.now().toDate().toISOString() });
    transaction.create(db.collection("auditLogs").doc(), {
      action: "report.resolved",
      reportId,
      actorUid: uid,
      created_at: Timestamp.now().toDate().toISOString(),
    });
  });
  return { ok: true, reportId };
});

function numericIdForUid(uid: string): number {
  const digest = createHash("sha256").update(uid).digest();
  return digest.readUInt32BE(0) & 0x7fffffff;
}

/**
 * Create the least-privileged user profile when Firebase Auth creates an
 * account. The transaction makes retries safe and preserves any profile that
 * the current Flutter client has already created with Security Rules.
 */
export const initializeUserProfile = onUserCreated({ region: FUNCTION_REGION }, async (event) => {
  const user = event.data;
  if (!user?.uid) {
    logger.error("Auth create event did not include a UID", { eventId: event.id });
    return;
  }
  const userRef = db.collection("users").doc(user.uid);
  await db.runTransaction(async (transaction) => {
    const existing = await transaction.get(userRef);
    if (existing.exists) return;

    transaction.create(userRef, {
      numericId: numericIdForUid(user.uid),
      name: user.displayName ?? user.email?.split("@")[0] ?? "Customer",
      email: user.email ?? "",
      role: "customer",
      ownedStoreIds: [],
      memberStoreIds: [],
      storeGrants: [],
    });
  });
  logger.info("Initialized customer profile", { role: "customer" });
});
