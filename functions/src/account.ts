import { getAuth } from "firebase-admin/auth";
import { FieldPath, Timestamp } from "firebase-admin/firestore";
import { HttpsError, onCall } from "firebase-functions/v2/https";
import { db } from "./admin";
import { enforceCallableAppCheck } from "./callable_options";
import { deleteStoredObject } from "./media_quota";
import { R2_GATEWAY_PRIVATE_JWK } from "./r2_gateway";

const CALLABLE_OPTIONS = { region: "asia-southeast1", enforceAppCheck: enforceCallableAppCheck, secrets: [R2_GATEWAY_PRIVATE_JWK] };
const RECENT_AUTH_MS = 5 * 60 * 1000;

async function deleteMatching(collection: string, field: string, uid: string): Promise<void> {
  while (true) {
    const matches = await db.collection(collection).where(field, "==", uid).limit(400).get();
    if (matches.empty) return;
    const batch = db.batch();
    for (const doc of matches.docs) batch.delete(doc.ref);
    await batch.commit();
  }
}

async function cleanProductMedia(uid: string): Promise<void> {
  while (true) {
    const matches = await db.collection("mediaAssets").where("uid", "==", uid).limit(300).get();
    if (matches.empty) return;
    const batch = db.batch();
    const files = new Set<string>();
    for (const doc of matches.docs) {
      const data = doc.data();
      if (data.status === "ready" && data.linkedProductId != null) {
        // Keep catalog media in use, but remove its uploader identity.
        batch.update(doc.ref, { uid: null, uploaderDeletedAt: Timestamp.now() });
      } else {
        const ownedPrefixes = [
          `products/quarantine/${uid}/`,
          `products/public/${uid}/`,
          `stores/quarantine/${uid}/`,
          `stores/processed/${uid}/`,
          `tours/originals/${uid}/`,
        ];
        for (const path of [data.quarantinePath, data.publicPath, data.privatePath, data.originalPath, data.pendingOutputPath, data.pendingPublicPath, data.objectKey]) {
          if (typeof path === "string" && ownedPrefixes.some((prefix) => path.startsWith(prefix))) {
            files.add(path);
          }
        }
        batch.update(doc.ref, { status: "deleting", cleanupStartedAt: Timestamp.now() });
      }
    }
    await Promise.all([...files].map(async (key) => {
      await deleteStoredObject(key, "system:account-cleanup", "account-deletion");
    }));
    for (const doc of matches.docs) {
      if (doc.data().status !== "ready" || doc.data().linkedProductId == null) {
        batch.update(doc.ref, {
          status: "deleted",
          accountingState: "deleted",
          deletedAt: Timestamp.now(),
          uid: null,
          uploaderDeletedAt: Timestamp.now(),
          updatedAt: Timestamp.now(),
        });
      }
    }
    await batch.commit();
  }
}

async function deleteOwnedTours(uid: string): Promise<void> {
  const pageSize = 100;
  let cursor: FirebaseFirestore.QueryDocumentSnapshot | undefined;
  while (true) {
    let query = db.collection("tours")
      .where("ownerUid", "==", uid)
      .orderBy(FieldPath.documentId())
      .limit(pageSize);
    if (cursor) query = query.startAfter(cursor);
    const tours = await query.get();
    if (tours.empty) return;

    const privateFiles = new Set<string>();
    for (const tour of tours.docs) {
      const nodes = tour.data().nodes;
      if (Array.isArray(nodes)) {
        for (const node of nodes) {
          const path = (node as { original_path?: unknown }).original_path;
          if (typeof path === "string" && path.startsWith(`tours/originals/${uid}/`)) {
            privateFiles.add(path);
          }
        }
      }
    }
    const batch = db.batch();
    for (const tour of tours.docs) batch.delete(tour.ref);
    cursor = tours.docs[tours.docs.length - 1];
    await Promise.all([...privateFiles].map(async (key) => {
      await deleteStoredObject(key, "system:account-cleanup", "account-tour-deletion");
    }));
    await batch.commit();
    if (tours.size < pageSize) return;
  }
}

export const deleteUserAccount = onCall(CALLABLE_OPTIONS, async (request) => {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Sign in to continue.");
  const authTime = Number(request.auth?.token.auth_time ?? 0) * 1000;
  if (!Number.isFinite(authTime) || Date.now() - authTime > RECENT_AUTH_MS || authTime > Date.now() + 60_000) {
    throw new HttpsError("failed-precondition", "Sign in again before deleting your account.");
  }

  const profileRef = db.collection("users").doc(uid);
  const [profile, ownedStores] = await Promise.all([
    profileRef.get(),
    db.collection("stores").where("ownerUid", "==", uid).get(),
  ]);
  if (profile.data()?.role === "admin") {
    throw new HttpsError("failed-precondition", "Administrator accounts cannot be deleted in the app.");
  }
  const protectedStores = ownedStores.docs.filter((store) => ["approved", "suspended"].includes(String(store.data().status)));
  if (protectedStores.length > 0) {
    throw new HttpsError("failed-precondition", "Transfer store ownership before deleting this account.");
  }

  // Remove personal data and access grants; retain immutable audit history.
  await Promise.all([
    deleteMatching("favorites", "uid", uid),
    deleteMatching("feedback", "uid", uid),
    deleteMatching("reports", "uid", uid),
    deleteMatching("storeMembers", "userUid", uid),
    deleteMatching("systemRateLimits", "uid", uid),
    cleanProductMedia(uid),
    deleteOwnedTours(uid),
  ]);
  for (let index = 0; index < ownedStores.docs.length; index += 400) {
    const batch = db.batch();
    for (const store of ownedStores.docs.slice(index, index + 400)) batch.delete(store.ref);
    await batch.commit();
  }
  const sessions = await db.collection("vendorSessions").where("startedByUid", "==", uid).get();
  for (const session of sessions.docs) {
    await session.ref.update({
      lat: null,
      lng: null,
      ended_at: Timestamp.now().toDate().toISOString(),
      startedByUid: null,
    });
  }
  await profileRef.delete();
  await getAuth().deleteUser(uid);
  return { ok: true };
});
