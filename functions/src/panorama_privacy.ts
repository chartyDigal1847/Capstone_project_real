import { Timestamp } from "firebase-admin/firestore";
import { HttpsError, onCall } from "firebase-functions/v2/https";
import { db, objectData } from "./admin";
import { enforceCallableAppCheck } from "./callable_options";
import { objectLedgerRef, quotaRef, R2_STORAGE_LIMIT_BYTES } from "./media_quota";
import {
  r2Head,
  r2PrivateMediaUrl,
  r2PublishedPanoramaUrl,
  r2PublishPanoramaDerivative,
  R2_GATEWAY_PRIVATE_JWK,
  signGatewayToken,
} from "./r2_gateway";

const CALLABLE_OPTIONS = {
  region: "asia-southeast1",
  enforceAppCheck: enforceCallableAppCheck,
  secrets: [R2_GATEWAY_PRIVATE_JWK],
};

type ReviewInput = {
  tourId: number;
  nodeId: number;
  derivativeSha256: string;
  processingVersion: string;
  inspectedDirections: number[];
  acknowledgedMissRisk: true;
  acknowledgedManualInspection: true;
};

export function validatePanoramaReviewInput(data: Record<string, unknown>): ReviewInput {
  if (!Number.isSafeInteger(data.tourId) || Number(data.tourId) <= 0 ||
      !Number.isSafeInteger(data.nodeId) || Number(data.nodeId) <= 0) {
    throw new HttpsError("invalid-argument", "Valid tour and viewpoint IDs are required.");
  }
  if (typeof data.derivativeSha256 !== "string" || !/^[a-f0-9]{64}$/.test(data.derivativeSha256)) {
    throw new HttpsError("invalid-argument", "A lowercase derivative SHA-256 digest is required.");
  }
  if (typeof data.processingVersion !== "string" ||
      !/^localspot-panorama-local-v[0-9]{1,8}$/.test(data.processingVersion)) {
    throw new HttpsError("invalid-argument", "The panorama processing version is invalid.");
  }
  if (!Array.isArray(data.inspectedDirections) || data.inspectedDirections.length !== 48 ||
      data.inspectedDirections.some((value) => !Number.isSafeInteger(value) || Number(value) < 0 || Number(value) >= 48) ||
      new Set(data.inspectedDirections).size !== 48) {
    throw new HttpsError("failed-precondition", "All 48 owner-review directions must be inspected.");
  }
  if (data.acknowledgedMissRisk !== true || data.acknowledgedManualInspection !== true) {
    throw new HttpsError("failed-precondition", "Both owner-review acknowledgements are required.");
  }
  return {
    tourId: Number(data.tourId),
    nodeId: Number(data.nodeId),
    derivativeSha256: data.derivativeSha256,
    processingVersion: data.processingVersion,
    inspectedDirections: (data.inspectedDirections as number[]).slice().sort((a, b) => a - b),
    acknowledgedMissRisk: true,
    acknowledgedManualInspection: true,
  };
}

/** Persist owner attestation only for the server-verified, currently accounted derivative. */
export const recordTourPanoramaReview = onCall(CALLABLE_OPTIONS, async (request) => {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Sign in to continue.");
  const input = validatePanoramaReviewInput(objectData(request.data, "Panorama owner review"));
  const tours = await db.collection("tours").where("numericId", "==", input.tourId).limit(1).get();
  if (tours.empty) throw new HttpsError("not-found", "Tour was not found.");
  const tourRef = tours.docs[0].ref;
  const initial = tours.docs[0].data();
  const stores = await db.collection("stores").where("numericId", "==", initial.storeId).limit(1).get();
  if (stores.empty) throw new HttpsError("not-found", "Store was not found.");
  const storeRef = stores.docs[0].ref;

  return db.runTransaction(async (transaction) => {
    const [tourSnapshot, storeSnapshot] = await Promise.all([
      transaction.get(tourRef),
      transaction.get(storeRef),
    ]);
    const tour = tourSnapshot.data();
    const store = storeSnapshot.data();
    if (!tourSnapshot.exists || !tour || !storeSnapshot.exists || !store) {
      throw new HttpsError("not-found", "Tour or store was not found.");
    }
    if (tour.status !== "draft" || store.status !== "approved" ||
        store.ownerUid !== uid || tour.ownerUid !== uid) {
      throw new HttpsError("permission-denied", "Only the authenticated owner can review a draft tour viewpoint.");
    }
    if (Number(tour.storeId) !== Number(store.numericId)) {
      throw new HttpsError("failed-precondition", "Tour ownership metadata is inconsistent.");
    }
    if (!Array.isArray(tour.nodes)) throw new HttpsError("data-loss", "Tour viewpoint data is invalid.");
    const nodes = tour.nodes as FirebaseFirestore.DocumentData[];
    const index = nodes.findIndex((node) => Number(node?.id) === input.nodeId);
    if (index < 0) throw new HttpsError("not-found", "Viewpoint was not found.");
    const node = nodes[index];
    const expectedOriginalPrefix = `tours/originals/${uid}/${input.tourId}/`;
    if (typeof node.original_path !== "string" || !node.original_path.startsWith(expectedOriginalPrefix)) {
      throw new HttpsError("permission-denied", "The viewpoint original does not belong to this owner.");
    }
    const derivative = node.verified_derivative;
    const validRevisionId = typeof derivative?.revisionId === "string" && /^[a-f0-9]{32}$/.test(derivative.revisionId);
    const expectedKey = validRevisionId
      ? `tours/derivatives/${uid}/${input.tourId}/${input.nodeId}/${derivative.revisionId}_${input.derivativeSha256}.jpg`
      : "";
    if (!derivative || derivative.status !== "verified" ||
        derivative.objectKey !== expectedKey || derivative.sha256 !== input.derivativeSha256 ||
        derivative.contentType !== "image/jpeg" || !Number.isSafeInteger(derivative.size) || Number(derivative.size) <= 0 ||
        derivative.processingVersion !== input.processingVersion ||
        derivative.accountingState !== "counted" || typeof derivative.reservationId !== "string" ||
        typeof derivative.verifiedAt?.toMillis !== "function") {
      throw new HttpsError("failed-precondition", "The current panorama derivative has not been verified and quota-accounted by the backend.");
    }

    const previousReview = node.owner_review;
    if (node.owner_reviewed === true && previousReview?.ownerUid === uid &&
        previousReview.derivativeSha256 === input.derivativeSha256 &&
        previousReview.processingVersion === input.processingVersion &&
        JSON.stringify(previousReview.inspectedDirections) === JSON.stringify(input.inspectedDirections) &&
        previousReview.acknowledgedMissRisk === true && previousReview.acknowledgedManualInspection === true &&
        typeof previousReview.reviewedAt?.toDate === "function") {
      return {
        ok: true,
        tourId: input.tourId,
        nodeId: input.nodeId,
        review: {
          ownerUid: uid,
          reviewedAt: previousReview.reviewedAt.toDate().toISOString(),
          derivativeSha256: input.derivativeSha256,
          processingVersion: input.processingVersion,
          inspectedDirections: input.inspectedDirections,
          directionCount: 48,
          acknowledgedMissRisk: true,
          acknowledgedManualInspection: true,
          recordType: "owner-attestation-not-privacy-proof",
        },
      };
    }

    const reviewedAt = Timestamp.now();
    const review = {
      ownerUid: uid,
      reviewedAt,
      derivativeSha256: input.derivativeSha256,
      processingVersion: input.processingVersion,
      inspectedDirections: input.inspectedDirections,
      directionCount: 48,
      acknowledgedMissRisk: true,
      acknowledgedManualInspection: true,
      recordType: "owner-attestation-not-privacy-proof",
    };
    nodes[index] = { ...node, owner_review: review, owner_reviewed: true };
    transaction.update(tourRef, { nodes, updatedAt: reviewedAt });
    return {
      ok: true,
      tourId: input.tourId,
      nodeId: input.nodeId,
      review: {
        ownerUid: uid,
        reviewedAt: reviewedAt.toDate().toISOString(),
        derivativeSha256: input.derivativeSha256,
        processingVersion: input.processingVersion,
        inspectedDirections: input.inspectedDirections,
        directionCount: 48,
        acknowledgedMissRisk: true,
        acknowledgedManualInspection: true,
        recordType: "owner-attestation-not-privacy-proof",
      },
    };
  });
});

function currentDerivative(node: FirebaseFirestore.DocumentData, ownerUid: string, tourId: number) {
  const derivative = node?.verified_derivative;
  const review = node?.owner_review;
  if (node?.owner_reviewed !== true || !derivative || derivative.status !== "verified" ||
      derivative.accountingState !== "counted" || derivative.contentType !== "image/jpeg" ||
      !Number.isSafeInteger(derivative.size) || Number(derivative.size) <= 0 ||
      typeof derivative.sha256 !== "string" || !/^[a-f0-9]{64}$/.test(derivative.sha256) ||
      typeof derivative.revisionId !== "string" || typeof derivative.reservationId !== "string" ||
      !/^[a-f0-9]{32}$/.test(derivative.revisionId) ||
      derivative.objectKey !== `tours/derivatives/${ownerUid}/${tourId}/${Number(node.id)}/${derivative.revisionId}_${derivative.sha256}.jpg` ||
      !(derivative.verifiedAt instanceof Timestamp)) {
    throw new HttpsError("failed-precondition", "Every viewpoint needs a current backend-verified derivative.");
  }
  if (!review || review.ownerUid !== ownerUid || review.derivativeSha256 !== derivative.sha256 ||
      review.processingVersion !== derivative.processingVersion ||
      typeof review.processingVersion !== "string" || review.acknowledgedMissRisk !== true ||
      review.acknowledgedManualInspection !== true || review.directionCount !== 48 ||
      review.recordType !== "owner-attestation-not-privacy-proof" ||
      !Array.isArray(review.inspectedDirections) || review.inspectedDirections.length !== 48 ||
      new Set(review.inspectedDirections).size !== 48 ||
      review.inspectedDirections.some((value: unknown, index: number) => value !== index) ||
      !(review.reviewedAt instanceof Timestamp)) {
    throw new HttpsError("failed-precondition", "Every viewpoint needs the current owner's complete 48-direction attestation.");
  }
  return derivative;
}

async function requireTourAndStore(tourId: number) {
  const tours = await db.collection("tours").where("numericId", "==", tourId).limit(1).get();
  if (tours.empty) throw new HttpsError("not-found", "Tour was not found.");
  const tourRef = tours.docs[0].ref;
  const tour = tours.docs[0].data();
  const stores = await db.collection("stores").where("numericId", "==", tour.storeId).limit(1).get();
  if (stores.empty) throw new HttpsError("not-found", "Store was not found.");
  return { tourRef, tour, storeRef: stores.docs[0].ref, store: stores.docs[0].data() };
}

/** The only public panorama access issuer; it issues a short-lived token only for published, reviewed derivatives. */
export const getPublishedTourPanoramaAccess = onCall(CALLABLE_OPTIONS, async (request) => {
  const data = objectData(request.data, "Published panorama access details");
  if (!Number.isSafeInteger(data.tourId) || Number(data.tourId) <= 0 ||
      !Number.isSafeInteger(data.nodeId) || Number(data.nodeId) <= 0) {
    throw new HttpsError("invalid-argument", "Valid tour and viewpoint IDs are required.");
  }
  const tourId = Number(data.tourId);
  const nodeId = Number(data.nodeId);
  const { tour, store } = await requireTourAndStore(tourId);
  if (tour.status !== "published" || store.status !== "approved") throw new HttpsError("not-found", "Published media was not found.");
  if (!Array.isArray(tour.nodes)) throw new HttpsError("data-loss", "Tour viewpoint data is invalid.");
  const node = tour.nodes.find((row: FirebaseFirestore.DocumentData) => Number(row?.id) === nodeId);
  if (!node) throw new HttpsError("not-found", "Published media was not found.");
  const derivative = currentDerivative(node, String(tour.ownerUid), tourId);
  const [ledger, reservation, quota, actual] = await Promise.all([
    objectLedgerRef(derivative.objectKey).get(),
    db.collection("uploadReservations").doc(derivative.reservationId).get(),
    quotaRef.get(),
    r2Head(derivative.objectKey),
  ]);
  const ledgerData = ledger.data();
  const reservationData = reservation.data();
  const quotaData = quota.data();
  if (!ledger.exists || !ledgerData || ledgerData.accountingState !== "counted" || ledgerData.countedInQuota !== true ||
      ledgerData.objectKey !== derivative.objectKey || Number(ledgerData.sizeBytes) !== Number(derivative.size) ||
      ledgerData.uid !== tour.ownerUid || ledgerData.reservationId !== derivative.reservationId ||
      !reservation.exists || reservationData?.status !== "completed" || reservationData?.purpose !== "processed" ||
      Number(reservationData.actualBytes) !== Number(derivative.size) ||
      !quota.exists || quotaData?.storageProvider !== "cloudflare_r2" || quotaData?.limitBytes !== R2_STORAGE_LIMIT_BYTES ||
      !Number.isSafeInteger(quotaData?.usedBytes) || !Number.isSafeInteger(quotaData?.reservedBytes) ||
      Number(quotaData.usedBytes) + Number(quotaData.reservedBytes) > R2_STORAGE_LIMIT_BYTES ||
      !actual || actual.key !== derivative.objectKey || actual.size !== derivative.size || actual.contentType !== "image/jpeg" ||
      actual.uid !== tour.ownerUid || actual.mediaType !== "panorama-derivative" || actual.sha256 !== derivative.sha256 ||
      actual.publicApproved !== "true") {
    throw new HttpsError("failed-precondition", "Published derivative verification or finalized quota accounting is no longer valid.");
  }
  const token = signGatewayToken({
    scope: "media:public-read",
    objectKey: derivative.objectKey,
    tourId,
    nodeId,
    derivativeSha256: derivative.sha256,
  });
  return { url: r2PublishedPanoramaUrl(derivative.objectKey), token, expiresInSeconds: 300 };
});

/** Authenticated owner/admin retrieval of a private panorama original or derivative via the Worker. */
export const getPanoramaPrivateMediaAccess = onCall(CALLABLE_OPTIONS, async (request) => {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Sign in to continue.");
  const data = objectData(request.data, "Private panorama access details");
  if (!Number.isSafeInteger(data.tourId) || Number(data.tourId) <= 0 ||
      !Number.isSafeInteger(data.nodeId) || Number(data.nodeId) <= 0 ||
      !["original", "derivative"].includes(String(data.variant))) {
    throw new HttpsError("invalid-argument", "Valid tour, viewpoint, and private media type are required.");
  }
  const tourId = Number(data.tourId);
  const nodeId = Number(data.nodeId);
  const { tour, store } = await requireTourAndStore(tourId);
  const caller = await db.collection("users").doc(uid).get();
  const isAdmin = caller.data()?.role === "admin";
  if (!isAdmin && (tour.ownerUid !== uid || store.ownerUid !== uid)) {
    throw new HttpsError("permission-denied", "Only this tour's owner can access its private media.");
  }
  if (!Array.isArray(tour.nodes)) throw new HttpsError("data-loss", "Tour viewpoint data is invalid.");
  const node = tour.nodes.find((row: FirebaseFirestore.DocumentData) => Number(row?.id) === nodeId);
  if (!node) throw new HttpsError("not-found", "Private media was not found.");
  let objectKey: string;
  if (data.variant === "original") {
    objectKey = node.original_path;
    if (typeof objectKey !== "string" || !objectKey.startsWith(`tours/originals/${tour.ownerUid}/${tourId}/`)) {
      throw new HttpsError("failed-precondition", "The private original is unavailable.");
    }
  } else {
    const derivative = node.verified_derivative;
    if (!derivative || derivative.status !== "verified" || derivative.accountingState !== "counted") {
      throw new HttpsError("failed-precondition", "The private derivative is unavailable.");
    }
    objectKey = derivative.objectKey;
  }
  const actual = await r2Head(objectKey);
  if (!actual || actual.key !== objectKey || actual.uid !== tour.ownerUid ||
      actual.size <= 0 || actual.contentType !== "image/jpeg" ||
      (data.variant === "original" ? actual.mediaType !== "panorama" :
        actual.mediaType !== "panorama-derivative" || actual.sha256 !== node.verified_derivative.sha256)) {
    throw new HttpsError("not-found", "Private media was not found.");
  }
  const token = signGatewayToken({ scope: "media:read", objectKey }, uid);
  return { url: r2PrivateMediaUrl(objectKey), token, expiresInSeconds: 300, contentType: actual.contentType };
});

/** Publish only after every current derivative, quota row, and owner attestation passes backend checks. */
export const publishStoreTour = onCall(CALLABLE_OPTIONS, async (request) => {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Sign in to continue.");
  const data = objectData(request.data, "Tour publication details");
  if (!Number.isSafeInteger(data.tourId) || Number(data.tourId) <= 0) throw new HttpsError("invalid-argument", "A valid tour ID is required.");
  const tourId = Number(data.tourId);
  const initial = await requireTourAndStore(tourId);
  if (initial.tour.ownerUid !== uid || initial.store.ownerUid !== uid || initial.store.status !== "approved") {
    throw new HttpsError("permission-denied", "Only the authenticated store owner can publish this tour.");
  }
  if (!Array.isArray(initial.tour.nodes) || initial.tour.nodes.length < 2 || initial.tour.status !== "draft") {
    throw new HttpsError("failed-precondition", "A draft tour with at least two reviewed viewpoints is required.");
  }
  const nodes = initial.tour.nodes as FirebaseFirestore.DocumentData[];
  const derivatives = nodes.map((node) => ({ node, derivative: currentDerivative(node, uid, tourId) }));
  const ledgerRefs = derivatives.map(({ derivative }) => objectLedgerRef(derivative.objectKey));
  const reservationRefs = derivatives.map(({ derivative }) => db.collection("uploadReservations").doc(derivative.reservationId));
  const [quotaSnapshot, ...accounting] = await Promise.all([
    quotaRef.get(),
    ...ledgerRefs.map((ref) => ref.get()),
    ...reservationRefs.map((ref) => ref.get()),
  ]);
  const quotaData = quotaSnapshot.data();
  if (!quotaSnapshot.exists || quotaData?.storageProvider !== "cloudflare_r2" || quotaData.limitBytes !== R2_STORAGE_LIMIT_BYTES ||
      !Number.isSafeInteger(quotaData.usedBytes) || !Number.isSafeInteger(quotaData.reservedBytes) ||
      quotaData.usedBytes < 0 || quotaData.reservedBytes < 0 || quotaData.usedBytes + quotaData.reservedBytes > R2_STORAGE_LIMIT_BYTES) {
    throw new HttpsError("failed-precondition", "R2 quota accounting is unavailable or inconsistent.");
  }
  const ledgerSnapshots = accounting.slice(0, derivatives.length) as FirebaseFirestore.DocumentSnapshot[];
  const reservationSnapshots = accounting.slice(derivatives.length) as FirebaseFirestore.DocumentSnapshot[];
  const objects = await Promise.all(derivatives.map(async ({ derivative }, index) => {
    const ledger = ledgerSnapshots[index].data();
    const reservation = reservationSnapshots[index].data();
    if (!ledgerSnapshots[index].exists || ledger?.accountingState !== "counted" || ledger.countedInQuota !== true ||
        ledger.objectKey !== derivative.objectKey || Number(ledger.sizeBytes) !== Number(derivative.size) ||
        ledger.uid !== uid || ledger.reservationId !== derivative.reservationId ||
        !reservationSnapshots[index].exists || reservation?.status !== "completed" || reservation.purpose !== "processed" ||
        Number(reservation.actualBytes) !== Number(derivative.size)) {
      throw new HttpsError("failed-precondition", "A panorama derivative is not finalized in the R2 quota ledger.");
    }
    const head = await r2Head(derivative.objectKey);
    if (!head || head.key !== derivative.objectKey || head.size !== derivative.size || head.contentType !== "image/jpeg" ||
        head.uid !== uid || head.mediaType !== "panorama-derivative" || head.sha256 !== derivative.sha256) {
      throw new HttpsError("failed-precondition", "A stored panorama derivative no longer matches its verified metadata.");
    }
    return { key: derivative.objectKey, nodeId: Number(index + 0), id: Number((derivatives[index].node.id)), sha256: derivative.sha256 };
  }));
  for (let index = 0; index < objects.length; index++) {
    const item = objects[index];
    await r2PublishPanoramaDerivative({ key: item.key, tourId, nodeId: Number(derivatives[index].node.id), sha256: item.sha256 });
  }

  const publishedAt = Timestamp.now();
  await db.runTransaction(async (transaction) => {
    const [tourSnapshot, storeSnapshot, currentQuota, ...currentAccounting] = await Promise.all([
      transaction.get(initial.tourRef),
      transaction.get(initial.storeRef),
      transaction.get(quotaRef),
      ...ledgerRefs.map((ref) => transaction.get(ref)),
      ...reservationRefs.map((ref) => transaction.get(ref)),
    ]);
    const tour = tourSnapshot.data();
    const store = storeSnapshot.data();
    const quota = currentQuota.data();
    if (!tourSnapshot.exists || !tour || !storeSnapshot.exists || !store || tour.status !== "draft" ||
        tour.ownerUid !== uid || store.ownerUid !== uid || store.status !== "approved" ||
        !quota || quota.storageProvider !== "cloudflare_r2" || quota.limitBytes !== R2_STORAGE_LIMIT_BYTES ||
        !Number.isSafeInteger(quota.usedBytes) || !Number.isSafeInteger(quota.reservedBytes) ||
        Number(quota.usedBytes) + Number(quota.reservedBytes) > R2_STORAGE_LIMIT_BYTES || !Array.isArray(tour.nodes)) {
      throw new HttpsError("failed-precondition", "Tour ownership, draft status, or quota accounting changed during publication.");
    }
    const currentNodes = tour.nodes as FirebaseFirestore.DocumentData[];
    if (currentNodes.length !== derivatives.length) throw new HttpsError("aborted", "The tour changed during publication. Retry after reviewing it again.");
    for (let index = 0; index < derivatives.length; index++) {
      const current = currentNodes.find((node) => Number(node.id) === Number(derivatives[index].node.id));
      const derivative = current ? currentDerivative(current, uid, tourId) : null;
      const ledger = currentAccounting[index].data();
      const reservation = currentAccounting[index + derivatives.length].data();
      if (!derivative || derivative.objectKey !== derivatives[index].derivative.objectKey ||
          derivative.sha256 !== derivatives[index].derivative.sha256 || derivative.revisionId !== derivatives[index].derivative.revisionId ||
          ledger?.accountingState !== "counted" || ledger.countedInQuota !== true ||
          reservation?.status !== "completed" || reservation.purpose !== "processed") {
        throw new HttpsError("aborted", "A viewpoint changed during publication. Review the current derivative again.");
      }
    }
    transaction.update(initial.tourRef, { status: "published", publishedAt, updatedAt: publishedAt });
  });
  return { ok: true, tourId, status: "published" };
});
