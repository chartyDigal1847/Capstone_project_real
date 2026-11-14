import { getAuth } from "firebase-admin/auth";
import { randomUUID } from "node:crypto";
import { getStorage } from "firebase-admin/storage";
import { Timestamp } from "firebase-admin/firestore";
import { HttpsError, onCall, type CallableRequest } from "firebase-functions/v2/https";
import { db, objectData } from "./admin";
import { encodeGeohash } from "./geo";
import { enforceCallableAppCheck } from "./callable_options";

const CALLABLE_OPTIONS = { region: "asia-southeast1", enforceAppCheck: enforceCallableAppCheck };
const STORE_APPLICATION_WINDOW_MS = 24 * 60 * 60 * 1000;
const MAX_STORE_APPLICATIONS_PER_WINDOW = 3;
const STORE_TYPES = new Set([
  "sariSari", "fruitVegetable", "marketStall", "streetVendor", "convenience",
  "supermarket", "generalMerchandise", "hardware", "electronics", "appliance",
  "clothing", "bookstore", "autoParts", "other",
]);

function requireUid(request: { auth?: { uid: string } | null }): string {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Sign in to continue.");
  return uid;
}

function text(value: unknown, field: string, maxLength: number, required = false): string {
  if (typeof value !== "string") {
    if (!required && value == null) return "";
    throw new HttpsError("invalid-argument", `${field} must be text.`);
  }
  const normalized = value.trim();
  if (normalized.length > maxLength || (required && normalized.length === 0)) {
    throw new HttpsError("invalid-argument", `${field} is invalid.`);
  }
  return normalized;
}

function coordinate(value: unknown, field: string, min: number, max: number): number {
  if (typeof value !== "number" || !Number.isFinite(value) || value < min || value > max) {
    throw new HttpsError("invalid-argument", `${field} is outside its valid range.`);
  }
  return value;
}

export const submitStoreApplication = onCall(CALLABLE_OPTIONS, async (request) => {
  const uid = requireUid(request);
  const data = objectData(request.data, "Store application details");
  const userRef = db.collection("users").doc(uid);
  const user = await userRef.get();
  if (!user.exists) throw new HttpsError("failed-precondition", "Your account profile is not ready yet.");
  if (user.data()?.role === "admin") {
    throw new HttpsError("failed-precondition", "Administrators cannot submit store applications.");
  }

  const storeType = text(data.type, "type", 40, true);
  if (!STORE_TYPES.has(storeType)) throw new HttpsError("invalid-argument", "Store type is not supported.");
  if (typeof data.is_mobile !== "boolean") {
    throw new HttpsError("invalid-argument", "is_mobile must be a boolean.");
  }
  const isMobile = data.is_mobile;
  const name = text(data.name, "name", 80, true);
  const lat = coordinate(data.lat, "lat", -90, 90);
  const lng = coordinate(data.lng, "lng", -180, 180);
  const storeRef = db.collection("stores").doc();
  const sequenceRef = db.collection("systemCounters").doc("storeIds");
  const now = Timestamp.now();
  const imageAssetId = data.imageAssetId == null ? "" : text(data.imageAssetId, "imageAssetId", 100);
  const mediaRef = imageAssetId ? db.collection("mediaAssets").doc(`${uid}_${imageAssetId}`) : null;
  const applicationLimitRef = db.collection("systemRateLimits").doc(`${uid}_storeApplication`);
  const pendingApplications = db.collection("stores")
    .where("ownerUid", "==", uid)
    .where("status", "==", "pending")
    .limit(1);
  let numericId = 0;
  await db.runTransaction(async (transaction) => {
    const [limit, pending, sequence] = await Promise.all([
      transaction.get(applicationLimitRef),
      transaction.get(pendingApplications),
      transaction.get(sequenceRef),
    ]);
    if (!pending.empty) {
      throw new HttpsError("already-exists", "You already have a store application awaiting review.");
    }
    const previousStart = limit.data()?.windowStartedAt;
    const previousStartMs = previousStart instanceof Timestamp ? previousStart.toMillis() : null;
    const elapsedMs = previousStartMs == null ? null : now.toMillis() - previousStartMs;
    const inCurrentWindow = elapsedMs != null && elapsedMs >= 0 && elapsedMs < STORE_APPLICATION_WINDOW_MS;
    const windowStartedAt = inCurrentWindow ? previousStart as Timestamp : now;
    const previousCount = inCurrentWindow ? Number(limit.data()?.count ?? 0) : 0;
    if (previousCount >= MAX_STORE_APPLICATIONS_PER_WINDOW) {
      throw new HttpsError("resource-exhausted", "You have reached the store application limit. Try again tomorrow.");
    }
    let highestId = 0;
    if (!sequence.exists) {
      const highest = await transaction.get(
        db.collection("stores").orderBy("numericId", "desc").limit(1),
      );
      highestId = Number(highest.docs[0]?.data().numericId ?? 0);
    }
    numericId = sequence.exists
      ? Number(sequence.data()?.value ?? 0) + 1
      : highestId + 1;
    if (!Number.isSafeInteger(numericId) || numericId <= 0) {
      throw new HttpsError("resource-exhausted", "A store ID could not be allocated safely.");
    }
    let media: FirebaseFirestore.DocumentSnapshot | undefined;
    if (mediaRef) {
      media = await transaction.get(mediaRef);
      const mediaData = media.data();
      if (!media.exists || mediaData?.uid !== uid || mediaData.mediaType !== "store" ||
          mediaData.status !== "ready" || mediaData.linkedStoreId != null || typeof mediaData.privatePath !== "string") {
        throw new HttpsError("failed-precondition", "The store photo has not finished processing or was already used.");
      }
    }
    transaction.create(storeRef, {
      numericId,
      ownerId: Number(user.data()?.numericId ?? 0),
      ownerUid: uid,
      name,
      type: storeType,
      status: "pending",
      lat,
      lng,
      geohash: encodeGeohash(lat, lng),
      barangay: text(data.barangay, "barangay", 80),
      city: text(data.city, "city", 80),
      address: text(data.address, "address", 160),
      landmark: text(data.landmark, "landmark", 160),
      schedule: text(data.schedule, "schedule", 120),
      is_mobile: isMobile,
      image: "",
      verification_note: text(data.verification_note, "verification_note", 500),
      location_mode: isMobile ? "regular" : "fixed",
      location_updated_at: now.toDate().toISOString(),
    });
    if (mediaRef) {
      transaction.update(mediaRef, {
        linkedStoreId: numericId,
        linkedAt: now.toDate().toISOString(),
        updatedAt: now,
      });
    }
    transaction.set(applicationLimitRef, {
      uid,
      operation: "storeApplication",
      windowStartedAt,
      count: previousCount + 1,
      updatedAt: now,
    });
    transaction.set(sequenceRef, { value: numericId });
  });
  return { id: numericId, status: "pending" };
});

export const updateStore = onCall(CALLABLE_OPTIONS, async (request) => {
  const uid = requireUid(request);
  const data = objectData(request.data, "Store update");
  const storeId = data.storeId;
  if (typeof storeId !== "number" || !Number.isSafeInteger(storeId) || storeId <= 0) {
    throw new HttpsError("invalid-argument", "A valid store ID is required.");
  }
  const stores = await db.collection("stores").where("numericId", "==", storeId).limit(1).get();
  if (stores.empty) throw new HttpsError("not-found", "Store was not found.");
  const storeRef = stores.docs[0].ref;
  const store = stores.docs[0].data();
  const user = await db.collection("users").doc(uid).get();
  if (store.ownerUid !== uid && user.data()?.role !== "admin") {
    throw new HttpsError("permission-denied", "Only the store owner can change its location and details.");
  }
  if (data.type != null && !STORE_TYPES.has(String(data.type))) {
    throw new HttpsError("invalid-argument", "Store type is not supported.");
  }
  if (data.isMobile != null && typeof data.isMobile !== "boolean") {
    throw new HttpsError("invalid-argument", "isMobile must be a boolean.");
  }
  const lat = data.lat == null ? Number(store.lat) : coordinate(data.lat, "lat", -90, 90);
  const lng = data.lng == null ? Number(store.lng) : coordinate(data.lng, "lng", -180, 180);
  const geohash = encodeGeohash(lat, lng);
  await storeRef.update({
    lat,
    lng,
    geohash,
    ...(data.name != null ? { name: text(data.name, "name", 80, true) } : {}),
    ...(data.type != null ? { type: text(data.type, "type", 40, true) } : {}),
    ...(data.barangay != null ? { barangay: text(data.barangay, "barangay", 80) } : {}),
    ...(data.city != null ? { city: text(data.city, "city", 80) } : {}),
    ...(data.address != null ? { address: text(data.address, "address", 160) } : {}),
    ...(data.landmark != null ? { landmark: text(data.landmark, "landmark", 160) } : {}),
    ...(data.schedule != null ? { schedule: text(data.schedule, "schedule", 120) } : {}),
    ...(data.isMobile != null ? { is_mobile: data.isMobile } : {}),
    location_updated_at: Timestamp.now().toDate().toISOString(),
  });
  const listings = await db.collection("listings").where("storeId", "==", storeId).get();
  for (let index = 0; index < listings.docs.length; index += 400) {
    const batch = db.batch();
    for (const listing of listings.docs.slice(index, index + 400)) {
      batch.update(listing.ref, { lat, lng, geohash });
    }
    await batch.commit();
  }
  return { ok: true, storeId, geohash };
});

async function handleStoreReview(request: CallableRequest<Record<string, unknown>>, forcedStatus?: string) {
  const adminUid = requireUid(request);
  const storeId = request.data?.storeId;
  const nextStatus = forcedStatus ?? request.data?.status ?? "approved";
  if (typeof storeId !== "number" || !Number.isSafeInteger(storeId) || storeId <= 0) {
    throw new HttpsError("invalid-argument", "A valid store ID is required.");
  }
  if (typeof nextStatus !== "string" || !new Set(["approved", "rejected", "suspended"]).has(nextStatus)) {
    throw new HttpsError("invalid-argument", "Store status is not supported.");
  }

  const admin = await db.collection("users").doc(adminUid).get();
  if (!admin.exists || admin.data()?.role !== "admin") {
    throw new HttpsError("permission-denied", "Administrator access is required.");
  }

  const matches = await db.collection("stores").where("numericId", "==", storeId).limit(1).get();
  if (matches.empty) throw new HttpsError("not-found", "Store application was not found.");
  const storeRef = matches.docs[0].ref;
  const initialStore = matches.docs[0].data();
  let imageMediaRef: FirebaseFirestore.DocumentReference | undefined;
  let publicImagePath: string | undefined;
  let publicImageUrl: string | undefined;
  if (nextStatus === "approved") {
    const imageMedia = await db.collection("mediaAssets").where("linkedStoreId", "==", storeId).limit(1).get();
    if (!imageMedia.empty) {
      imageMediaRef = imageMedia.docs[0].ref;
      const imageMediaData = imageMedia.docs[0].data();
      if (imageMediaData.uid !== initialStore.ownerUid || imageMediaData.mediaType !== "store" ||
          imageMediaData.status !== "ready" || typeof imageMediaData.privatePath !== "string") {
        throw new HttpsError("failed-precondition", "The store photo is not ready for publication.");
      }
      if (typeof initialStore.image !== "string" || initialStore.image.length === 0) {
        const bucket = getStorage().bucket();
        const [imageBytes] = await bucket.file(imageMediaData.privatePath).download();
        const extension = imageMediaData.privatePath.split(".").at(-1) ?? "jpg";
        publicImagePath = `stores/public/${storeId}/${imageMediaData.assetId}.${extension}`;
        const token = randomUUID();
        await bucket.file(publicImagePath).save(imageBytes, {
          resumable: false,
          metadata: {
            contentType: imageMediaData.contentType,
            cacheControl: "public,max-age=86400",
            metadata: { firebaseStorageDownloadTokens: token, metadataStripped: "true" },
          },
        });
        publicImageUrl = `https://firebasestorage.googleapis.com/v0/b/${bucket.name}/o/${encodeURIComponent(publicImagePath)}?alt=media&token=${token}`;
      }
    }
  }

  let resultStatus: string;
  try {
    resultStatus = await db.runTransaction(async (transaction) => {
    const storeSnap = await transaction.get(storeRef);
    const store = storeSnap.data();
    if (!storeSnap.exists) {
      throw new HttpsError("not-found", "Store application was not found.");
    }
    if (store?.status === nextStatus && !publicImageUrl) return nextStatus;
    if (store?.status === "rejected" || store?.status === "suspended") {
      if (nextStatus !== "approved" || store.status === "rejected") {
        throw new HttpsError("failed-precondition", "This store cannot transition to the requested status.");
      }
    } else if (store?.status !== "pending" && store?.status !== "approved") {
      throw new HttpsError("failed-precondition", "This store cannot transition to the requested status.");
    }
    const ownerRef = db.collection("users").doc(String(store.ownerUid));
    const ownerSnap = await transaction.get(ownerRef);
    if (!ownerSnap.exists) throw new HttpsError("failed-precondition", "Store owner profile is missing.");
    const ownedStoreIds = (ownerSnap.data()?.ownedStoreIds as number[] | undefined) ?? [];
    if (imageMediaRef && publicImagePath) {
      const imageMedia = await transaction.get(imageMediaRef);
      if (imageMedia.data()?.linkedStoreId !== storeId || imageMedia.data()?.status !== "ready") {
        throw new HttpsError("failed-precondition", "The store photo changed during review.");
      }
    }
    transaction.update(storeRef, {
      status: nextStatus,
      geohash: encodeGeohash(Number(store.lat), Number(store.lng)),
      ...(publicImageUrl ? { image: publicImageUrl } : {}),
    });
    if (imageMediaRef && publicImagePath) {
      transaction.update(imageMediaRef, { publicPath: publicImagePath, publishedAt: Timestamp.now().toDate().toISOString() });
    }
    if (nextStatus === "approved") {
      transaction.update(ownerRef, {
        role: "owner",
        ownedStoreIds: [...new Set([...ownedStoreIds, storeId])],
      });
    }
    transaction.create(db.collection("auditLogs").doc(), {
      action: `store.status.${nextStatus}`,
      storeId,
      actorUid: adminUid,
      ownerUid: store.ownerUid,
      created_at: Timestamp.now().toDate().toISOString(),
    });
    return nextStatus;
    });
  } catch (error) {
    if (publicImagePath) await getStorage().bucket().file(publicImagePath).delete({ ignoreNotFound: true }).catch(() => undefined);
    throw error;
  }

  return { id: storeId, status: resultStatus };
}

export const reviewStoreApplication = onCall(CALLABLE_OPTIONS, (request) => handleStoreReview(request));

export const approveStoreApplication = onCall(CALLABLE_OPTIONS, async (request) => {
  return handleStoreReview(request, "approved");
});

export const manageStoreMembership = onCall(CALLABLE_OPTIONS, async (request) => {
  const callerUid = requireUid(request);
  const data = objectData(request.data, "Membership details");
  const storeId = data?.storeId;
  if (typeof storeId !== "number" || !Number.isSafeInteger(storeId) || storeId <= 0) {
    throw new HttpsError("invalid-argument", "A valid store ID is required.");
  }
  const email = data.email == null ? "" : text(data.email, "email", 120).toLowerCase();
  const targetNumericId = data.userNumericId;
  if (!email && (typeof targetNumericId !== "number" || !Number.isSafeInteger(targetNumericId) || targetNumericId <= 0)) {
    throw new HttpsError("invalid-argument", "Provide a staff email or user ID.");
  }
  const action = data.action;
  if (action !== "set" && action !== "remove") {
    throw new HttpsError("invalid-argument", "Action must be set or remove.");
  }
  const suppliedGrants = [data.inventory, data.promotions, data.location].filter((grant) => grant != null);
  if (action === "set" && suppliedGrants.some((grant) => typeof grant !== "boolean")) {
    throw new HttpsError("invalid-argument", "Store grants must be booleans.");
  }

  const storeQuery = await db.collection("stores").where("numericId", "==", storeId).limit(1).get();
  if (storeQuery.empty) throw new HttpsError("not-found", "Store was not found.");
  const caller = await db.collection("users").doc(callerUid).get();
  const isAdmin = caller.data()?.role === "admin";
  if (!isAdmin && storeQuery.docs[0].data().ownerUid !== callerUid) {
    throw new HttpsError("permission-denied", "Only the store owner can manage its staff.");
  }
  let targetAuth = null;
  if (email) {
    targetAuth = await getAuth().getUserByEmail(email).catch(() => null);
  } else {
    const targetProfiles = await db.collection("users").where("numericId", "==", targetNumericId).limit(1).get();
    if (!targetProfiles.empty) targetAuth = await getAuth().getUser(targetProfiles.docs[0].id).catch(() => null);
  }
  if (!targetAuth) throw new HttpsError("not-found", "No LocalSpot account matches that user.");
  if (targetAuth.uid === storeQuery.docs[0].data().ownerUid) {
    throw new HttpsError("failed-precondition", "The store owner cannot be added as staff.");
  }
  const targetRef = db.collection("users").doc(targetAuth.uid);
  const matchingMembers = await db.collection("storeMembers")
    .where("storeId", "==", storeId)
    .where("userUid", "==", targetAuth.uid)
    .limit(20)
    .get();
  const memberRef = matchingMembers.docs[0]?.ref ?? db.collection("storeMembers").doc(`${storeId}_${targetAuth.uid}`);

  await db.runTransaction(async (transaction) => {
    const target = await transaction.get(targetRef);
    if (!target.exists) throw new HttpsError("failed-precondition", "Staff account profile is missing.");
    if (target.data()?.role === "admin") {
      throw new HttpsError("failed-precondition", "Administrators cannot be added as store staff.");
    }
    const memberStoreIds = (target.data()?.memberStoreIds as number[] | undefined) ?? [];
    const previousGrants = matchingMembers.docs[0]?.data() ?? {};
    const nextMemberships = action === "set"
      ? [...new Set([...memberStoreIds, storeId])]
      : memberStoreIds.filter((id) => id !== storeId);

    if (action === "set") {
      transaction.set(memberRef, {
        storeId,
        email: targetAuth.email ?? email,
        userUid: targetAuth.uid,
        userNumericId: Number(target.data()?.numericId ?? 0),
        inventory: data.inventory == null ? previousGrants.inventory === true : data.inventory,
        promotions: data.promotions == null ? previousGrants.promotions === true : data.promotions,
        location: data.location == null ? previousGrants.location === true : data.location,
      });
      for (const duplicate of matchingMembers.docs.slice(1)) transaction.delete(duplicate.ref);
      transaction.update(targetRef, {
        memberStoreIds: nextMemberships,
        role: target.data()?.role === "owner" ? "owner" : "staff",
      });
    } else {
      for (const staleMember of matchingMembers.docs) transaction.delete(staleMember.ref);
      transaction.update(targetRef, {
        memberStoreIds: nextMemberships,
        role: target.data()?.role === "staff" && nextMemberships.length === 0 ? "customer" : target.data()?.role,
      });
    }
    transaction.create(db.collection("auditLogs").doc(), {
      action: `store.membership.${action}`,
      storeId,
      actorUid: callerUid,
      targetUid: targetAuth.uid,
      created_at: Timestamp.now().toDate().toISOString(),
    });
  });
  return { ok: true, action, storeId, uid: targetAuth.uid };
});

export const listStoreMemberships = onCall(CALLABLE_OPTIONS, async (request) => {
  const callerUid = requireUid(request);
  const data = objectData(request.data, "Membership details");
  const storeId = data.storeId;
  if (typeof storeId !== "number" || !Number.isSafeInteger(storeId) || storeId <= 0) {
    throw new HttpsError("invalid-argument", "A valid store ID is required.");
  }
  const [storeQuery, caller] = await Promise.all([
    db.collection("stores").where("numericId", "==", storeId).limit(1).get(),
    db.collection("users").doc(callerUid).get(),
  ]);
  if (storeQuery.empty || !caller.exists) throw new HttpsError("not-found", "Store was not found.");
  if (storeQuery.docs[0].data().ownerUid !== callerUid && caller.data()?.role !== "admin") {
    throw new HttpsError("permission-denied", "Only the store owner or an administrator can view staff.");
  }
  const memberships = await db.collection("storeMembers")
    .where("storeId", "==", storeId)
    .limit(100)
    .get();
  const profiles = await Promise.all(memberships.docs.map((membership) =>
    db.collection("users").doc(String(membership.data().userUid ?? "")).get(),
  ));
  return {
    members: memberships.docs.flatMap((membership, index) => {
      const profile = profiles[index];
      if (!profile.exists) return [];
      const user = profile.data()!;
      const grants = membership.data();
      return [{
        id: Number(user.numericId ?? 0),
        name: String(user.name ?? ""),
        email: String(user.email ?? grants.email ?? ""),
        role: String(user.role ?? "customer"),
        owned_store_ids: Array.isArray(user.ownedStoreIds) ? user.ownedStoreIds : [],
        member_store_ids: Array.isArray(user.memberStoreIds) ? user.memberStoreIds : [],
        store_grants: [{
          store_id: storeId,
          inventory: grants.inventory === true,
          promotions: grants.promotions === true,
          location: grants.location === true,
        }],
      }];
    }),
  };
});
