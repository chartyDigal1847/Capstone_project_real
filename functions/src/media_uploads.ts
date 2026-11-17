import { randomUUID } from "node:crypto";
import { FieldValue, Timestamp } from "firebase-admin/firestore";
import { HttpsError, onCall } from "firebase-functions/v2/https";
import * as logger from "firebase-functions/logger";
import { db, consumeRateLimit, objectData } from "./admin";
import { enforceCallableAppCheck } from "./callable_options";
import { verifyStoredPanoramaDerivative } from "./panorama_derivative_validation";
import { FORMATS, MAX_BYTES, stripImageMetadata } from "./image_sanitizer";
import {
  completeStorageReservation,
  deleteStoredObject,
  releaseStorageReservation,
  reserveStorageBytes,
  UPLOAD_IN_FLIGHT_GRACE_MS,
  UPLOAD_TOKEN_TTL_MS,
} from "./media_quota";
import {
  r2Delete,
  r2Head,
  r2PrivateMediaUrl,
  r2PublicMediaUrl,
  r2Put,
  r2Read,
  r2UploadUrl,
  R2_GATEWAY_PRIVATE_JWK,
  signGatewayToken,
} from "./r2_gateway";

const FUNCTION_REGION = "asia-southeast1";
const MAX_PANORAMA_BYTES = 50 * 1024 * 1024;
const CALLABLE_OPTIONS = {
  region: FUNCTION_REGION,
  enforceAppCheck: enforceCallableAppCheck,
  secrets: [R2_GATEWAY_PRIVATE_JWK],
};

function requireUid(request: { auth?: { uid: string } | null }): string {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Sign in to continue.");
  return uid;
}
function uploadKey(uid: string, mediaType: "product" | "store" | "panorama", assetId: string, tourId?: number): string {
  if (mediaType === "product") return `products/quarantine/${uid}/${assetId}`;
  if (mediaType === "store") return `stores/quarantine/${uid}/${assetId}`;
  return `tours/originals/${uid}/${tourId}/${assetId}`;
}

async function authorizeUpload(uid: string, mediaType: "product" | "store" | "panorama", tourId?: number): Promise<void> {
  const user = await db.collection("users").doc(uid).get();
  if (!user.exists) throw new HttpsError("failed-precondition", "Your account profile is not ready yet.");
  const role = String(user.data()?.role ?? "");
  if (mediaType === "product" && !["owner", "staff", "admin"].includes(role)) {
    throw new HttpsError("permission-denied", "Store product image upload permission is required.");
  }
  if (mediaType === "store" && role === "admin") {
    throw new HttpsError("permission-denied", "Administrators cannot submit store applications.");
  }
  if (mediaType !== "panorama") return;
  if (!tourId || !Number.isSafeInteger(tourId)) throw new HttpsError("invalid-argument", "A valid tour ID is required.");
  const tours = await db.collection("tours").where("numericId", "==", tourId).limit(1).get();
  if (tours.empty) throw new HttpsError("not-found", "Tour was not found.");
  const tour = tours.docs[0].data();
  const stores = await db.collection("stores").where("numericId", "==", tour.storeId).limit(1).get();
  if (stores.empty || stores.docs[0].data().status !== "approved") {
    throw new HttpsError("failed-precondition", "Only tours for approved stores can accept panoramas.");
  }
  const store = stores.docs[0].data();
  if (role !== "admin" && (store.ownerUid !== uid || tour.ownerUid !== uid || tour.status !== "draft")) {
    throw new HttpsError("permission-denied", "Only the tour owner or an administrator can upload its panoramas.");
  }
}

export const reserveMediaUpload = onCall(CALLABLE_OPTIONS, async (request) => {
  const uid = requireUid(request);
  const data = objectData(request.data, "Media upload details");
  if (!new Set(["product", "store", "panorama"]).has(String(data.mediaType))) {
    throw new HttpsError("invalid-argument", "The media type is not supported.");
  }
  const mediaType = data.mediaType as "product" | "store" | "panorama";
  if (typeof data.assetId !== "string" || !/^[A-Za-z0-9_-]{1,100}$/.test(data.assetId)) {
    throw new HttpsError("invalid-argument", "A valid media ID is required.");
  }
  if (typeof data.contentType !== "string" || !FORMATS.some((format) => format.mime === data.contentType)) {
    throw new HttpsError("invalid-argument", "Use a JPEG, PNG, or WebP image.");
  }
  const maxBytes = mediaType === "panorama" ? MAX_PANORAMA_BYTES : MAX_BYTES;
  if (!Number.isSafeInteger(data.expectedBytes) || Number(data.expectedBytes) <= 0 || Number(data.expectedBytes) > maxBytes) {
    throw new HttpsError("invalid-argument", `The file must be no larger than ${mediaType === "panorama" ? "50 MiB" : "8 MiB"}.`);
  }
  const tourId = mediaType === "panorama" ? data.tourId : undefined;
  if (mediaType === "panorama" && (typeof tourId !== "number" || !Number.isSafeInteger(tourId) || tourId <= 0)) {
    throw new HttpsError("invalid-argument", "A valid tour ID is required.");
  }

  await authorizeUpload(uid, mediaType, tourId as number | undefined);
  await consumeRateLimit(uid, "mediaUpload", 10, 60 * 60 * 1000);

  const reservationId = randomUUID();
  const objectKey = uploadKey(uid, mediaType, data.assetId, tourId as number | undefined);
  const nowSeconds = Math.floor(Date.now() / 1000);
  const authExpiresAtSeconds = nowSeconds + UPLOAD_TOKEN_TTL_MS / 1000;
  const expiresAt = Timestamp.fromMillis(authExpiresAtSeconds * 1000 + UPLOAD_IN_FLIGHT_GRACE_MS);
  await reserveStorageBytes({
    reservationId,
    uid,
    assetId: data.assetId,
    mediaType,
    objectKey,
    reservedBytes: Number(data.expectedBytes),
    ...(tourId ? { tourId: tourId as number } : {}),
  }, expiresAt);

  const uploadToken = signGatewayToken({
    scope: "upload",
    objectKey,
    contentType: data.contentType,
    maxBytes: Number(data.expectedBytes),
    mediaType,
    assetId: data.assetId,
    ...(tourId ? { tourId } : {}),
    exp: authExpiresAtSeconds,
  }, uid, reservationId);
  return {
    reservationId,
    objectKey,
    uploadUrl: r2UploadUrl(reservationId),
    uploadToken,
    expiresAt: new Date(authExpiresAtSeconds * 1000).toISOString(),
  };
});

async function discardUpload(reservationId: string, objectKey: string, uid: string, reason: string): Promise<void> {
  const reservationRef = db.collection("uploadReservations").doc(reservationId);
  const reservation = await reservationRef.get();
  if (reservation.data()?.status === "completed") {
    await deleteStoredObject(objectKey, uid, reason);
  } else {
    await r2Delete(objectKey);
    if (await r2Head(objectKey)) throw new HttpsError("unavailable", "The invalid upload could not be removed from storage.");
    await releaseStorageReservation(reservationId, reason);
  }
  await db.collection("mediaAssets").doc(`${uid}_${reservation.data()?.assetId}`).set({
    status: "failed",
    accountingState: "deleted",
    reason,
    updatedAt: Timestamp.now(),
  }, { merge: true });
}

async function finishProcessedMedia(input: {
  uid: string;
  assetId: string;
  mediaType: "product" | "store";
  sourceKey: string;
  outputKey: string;
  outputBytes: number;
  contentType: string;
  extension: string;
  reservationId: string;
}): Promise<{ assetId: string; status: "ready"; downloadUrl?: string }> {
  const { uid, assetId, mediaType, sourceKey, outputKey, outputBytes, contentType, extension, reservationId } = input;
  const mediaRef = db.collection("mediaAssets").doc(`${uid}_${assetId}`);
  const output = await r2Head(outputKey);
  if (!output || output.size !== outputBytes || output.contentType !== contentType) {
    throw new HttpsError("data-loss", "The processed R2 object could not be verified.");
  }
  await mediaRef.set({
    status: "processing",
    pendingOutputPath: outputKey,
    pendingOutputSize: outputBytes,
    pendingContentType: contentType,
    processingReservationId: `${reservationId}_processed`,
    updatedAt: Timestamp.now(),
  }, { merge: true });

  if (await r2Head(sourceKey)) await deleteStoredObject(sourceKey, uid, "media-processed");

  const publicPath = mediaType === "product" ? outputKey : undefined;
  const privatePath = mediaType === "store" ? outputKey : undefined;
  const downloadUrl = publicPath ? r2PublicMediaUrl(publicPath) : undefined;
  await mediaRef.set({
    status: "ready",
    ...(publicPath ? { publicPath, downloadUrl } : { privatePath }),
    objectKey: outputKey,
    size: outputBytes,
    contentType,
    metadataStripped: true,
    accountingState: "counted",
    ...(extension ? { extension } : {}),
    pendingOutputPath: FieldValue.delete(),
    pendingOutputSize: FieldValue.delete(),
    pendingContentType: FieldValue.delete(),
    processingReservationId: FieldValue.delete(),
    updatedAt: Timestamp.now(),
  }, { merge: true });
  logger.info("Processed R2 media upload", { mediaType, bytes: outputBytes });
  return { assetId, status: "ready", ...(downloadUrl ? { downloadUrl } : {}) };
}

async function finishPanorama(uid: string, assetId: string, tourId: number, reservationId: string, objectKey: string, contentType: string, size: number) {
  await completeStorageReservation(reservationId, size, {
    status: "awaiting-privacy-processing",
    originalPath: objectKey,
    objectKey,
    tourId,
    contentType,
    size,
    accountingState: "counted",
  });
  return { assetId, status: "awaiting-privacy-processing", originalPath: objectKey };
}

export const finalizeMediaUpload = onCall(CALLABLE_OPTIONS, async (request) => {
  const uid = requireUid(request);
  if (!(await db.collection("users").doc(uid).get()).exists) {
    throw new HttpsError("permission-denied", "This account is no longer active.");
  }
  const data = objectData(request.data, "Media finalization details");
  if (typeof data.reservationId !== "string" || !/^[A-Za-z0-9_-]{16,128}$/.test(data.reservationId)) {
    throw new HttpsError("invalid-argument", "A valid upload reservation ID is required.");
  }
  const reservationRef = db.collection("uploadReservations").doc(data.reservationId);
  const reservationSnap = await reservationRef.get();
  if (!reservationSnap.exists) throw new HttpsError("not-found", "The upload reservation was not found.");
  const reservation = reservationSnap.data()!;
  if (reservation.uid !== uid || reservation.purpose !== "upload") {
    throw new HttpsError("permission-denied", "This upload reservation does not belong to your account.");
  }
  const mediaRef = db.collection("mediaAssets").doc(`${uid}_${reservation.assetId}`);
  const mediaSnap = await mediaRef.get();
  const media = mediaSnap.data();
  if (!mediaSnap.exists || media?.reservationId !== reservation.reservationId) {
    throw new HttpsError("failed-precondition", "Upload metadata is missing or inconsistent.");
  }
  const mediaData = media!;
  if (reservation.status === "released" || reservation.status === "failed") {
    throw new HttpsError("failed-precondition", "This upload reservation has expired or failed.");
  }
  if (mediaData.status === "ready" || mediaData.status === "awaiting-privacy-processing") {
    return {
      assetId: reservation.assetId,
      status: mediaData.status,
      ...(typeof mediaData.downloadUrl === "string" ? { downloadUrl: mediaData.downloadUrl } : {}),
      ...(typeof mediaData.originalPath === "string" ? { originalPath: mediaData.originalPath } : {}),
    };
  }

  if (mediaData.status === "processing" && typeof mediaData.pendingOutputPath === "string") {
    const pendingOutput = await r2Head(mediaData.pendingOutputPath);
    if (pendingOutput && pendingOutput.size === Number(mediaData.pendingOutputSize) &&
        pendingOutput.contentType === mediaData.pendingContentType) {
      const extension = String(mediaData.pendingOutputPath).split(".").at(-1) ?? "jpg";
      return finishProcessedMedia({
        uid,
        assetId: String(reservation.assetId),
        mediaType: reservation.mediaType,
        sourceKey: String(reservation.objectKey),
        outputKey: String(mediaData.pendingOutputPath),
        outputBytes: pendingOutput.size,
        contentType: String(mediaData.pendingContentType),
        extension,
        reservationId: data.reservationId,
      });
    }
  }

  const objectKey = String(reservation.objectKey);
  const actual = await r2Head(objectKey);
  if (!actual) {
    if (reservation.status === "reserved") {
      await releaseStorageReservation(data.reservationId, "upload-object-missing");
    } else if (reservation.status === "completed") {
      await deleteStoredObject(objectKey, uid, "upload-object-missing");
    }
    await mediaRef.set({ status: "failed", reason: "upload-object-missing", accountingState: "deleted", updatedAt: Timestamp.now() }, { merge: true });
    throw new HttpsError("not-found", "The R2 upload was not found. Upload the image again.");
  }
  if (actual.size > Number(reservation.reservedBytes) || actual.size <= 0 ||
      actual.reservationId !== data.reservationId || actual.uid !== uid || actual.mediaType !== reservation.mediaType) {
    await discardUpload(data.reservationId, objectKey, uid, "upload-verification-failed");
    throw new HttpsError("failed-precondition", "The stored object did not match its upload reservation.");
  }

  const bytes = await r2Read(objectKey);
  const format = FORMATS.find((candidate) => candidate.mime === actual.contentType);
  if (bytes.length !== actual.size || !format || !format.signature(bytes)) {
    await discardUpload(data.reservationId, objectKey, uid, "invalid-image-content");
    throw new HttpsError("invalid-argument", "The uploaded file is not a valid JPEG, PNG, or WebP image.");
  }

  if (reservation.mediaType === "panorama") {
    return finishPanorama(uid, String(reservation.assetId), Number(reservation.tourId), data.reservationId, objectKey, format.mime, bytes.length);
  }

  if (bytes.length > MAX_BYTES) {
    await discardUpload(data.reservationId, objectKey, uid, "image-exceeds-maximum-size");
    throw new HttpsError("resource-exhausted", "The image exceeds the 8 MiB limit.");
  }
  const sanitized = stripImageMetadata(bytes, format.mime);
  if (!sanitized || sanitized.length === 0 || sanitized.length > MAX_BYTES) {
    await discardUpload(data.reservationId, objectKey, uid, "invalid-image-structure");
    throw new HttpsError("invalid-argument", "The uploaded image could not be safely processed.");
  }

  await completeStorageReservation(data.reservationId, bytes.length, {
    status: "processing",
    quarantinePath: objectKey,
    objectKey,
    size: bytes.length,
    contentType: format.mime,
    accountingState: "counted",
  });
  const isProduct = reservation.mediaType === "product";
  const outputKey = isProduct
    ? `products/public/${uid}/${reservation.assetId}.${format.extension}`
    : `stores/processed/${uid}/${reservation.assetId}.${format.extension}`;
  const outputReservationId = `${data.reservationId}_processed`;
  const outputReservationExpires = Timestamp.fromMillis(Date.now() + UPLOAD_TOKEN_TTL_MS + UPLOAD_IN_FLIGHT_GRACE_MS);
  const outputReservationRef = db.collection("uploadReservations").doc(outputReservationId);
  const existingOutputReservation = await outputReservationRef.get();
  if (!existingOutputReservation.exists) {
    await reserveStorageBytes({
      reservationId: outputReservationId,
      uid,
      assetId: String(reservation.assetId),
      mediaType: reservation.mediaType,
      objectKey: outputKey,
      reservedBytes: sanitized.length,
      purpose: "processed",
    }, outputReservationExpires);
  } else if (existingOutputReservation.data()?.objectKey !== outputKey ||
      Number(existingOutputReservation.data()?.reservedBytes) !== sanitized.length) {
    throw new HttpsError("data-loss", "The processed-image reservation does not match the output.");
  }

  let output = await r2Head(outputKey);
  if (!output) {
    if (existingOutputReservation.exists && existingOutputReservation.data()?.status === "completed") {
      throw new HttpsError("data-loss", "A processed image is missing from R2 accounting.");
    }
    await r2Put(outputKey, sanitized, format.mime, sanitized.length, {
      reservationId: outputReservationId,
      uid,
      mediaType: reservation.mediaType,
    });
    output = await r2Head(outputKey);
  }
  if (!output || output.size !== sanitized.length || output.contentType !== format.mime) {
    throw new HttpsError("data-loss", "The processed image did not match its verified output size.");
  }
  await completeStorageReservation(outputReservationId, output.size);
  return finishProcessedMedia({
    uid,
    assetId: String(reservation.assetId),
    mediaType: reservation.mediaType,
    sourceKey: objectKey,
    outputKey,
    outputBytes: output.size,
    contentType: format.mime,
    extension: format.extension,
    reservationId: data.reservationId,
  });
});

/** Reserve an immutable, private JPEG derivative. The bucket must be reconciled before this can succeed. */
export const reservePanoramaDerivativeUpload = onCall(CALLABLE_OPTIONS, async (request) => {
  const uid = requireUid(request);
  const data = objectData(request.data, "Panorama derivative reservation");
  if (!Number.isSafeInteger(data.tourId) || Number(data.tourId) <= 0 ||
      !Number.isSafeInteger(data.nodeId) || Number(data.nodeId) <= 0) {
    throw new HttpsError("invalid-argument", "Valid tour and viewpoint IDs are required.");
  }
  if (typeof data.assetId !== "string" || !/^[A-Za-z0-9_-]{1,100}$/.test(data.assetId)) {
    throw new HttpsError("invalid-argument", "A valid original panorama media ID is required.");
  }
  if (data.contentType !== "image/jpeg") throw new HttpsError("invalid-argument", "Panorama derivatives must be JPEG images.");
  if (!Number.isSafeInteger(data.expectedBytes) || Number(data.expectedBytes) <= 0 || Number(data.expectedBytes) > MAX_PANORAMA_BYTES) {
    throw new HttpsError("invalid-argument", "The derivative must be no larger than 50 MiB.");
  }
  if (typeof data.derivativeSha256 !== "string" || !/^[a-f0-9]{64}$/.test(data.derivativeSha256)) {
    throw new HttpsError("invalid-argument", "A lowercase derivative SHA-256 digest is required.");
  }
  if (typeof data.processingVersion !== "string" || !/^localspot-panorama-local-v[0-9]{1,8}$/.test(data.processingVersion)) {
    throw new HttpsError("invalid-argument", "The panorama processing version is invalid.");
  }

  const tourId = Number(data.tourId);
  const nodeId = Number(data.nodeId);
  const tours = await db.collection("tours").where("numericId", "==", tourId).limit(1).get();
  if (tours.empty) throw new HttpsError("not-found", "Tour was not found.");
  const tour = tours.docs[0].data();
  const stores = await db.collection("stores").where("numericId", "==", tour.storeId).limit(1).get();
  if (stores.empty) throw new HttpsError("not-found", "Store was not found.");
  if (tour.status !== "draft" || tour.ownerUid !== uid || stores.docs[0].data().ownerUid !== uid || stores.docs[0].data().status !== "approved") {
    throw new HttpsError("permission-denied", "Only the authenticated owner can add a derivative to this draft tour.");
  }
  const node = (Array.isArray(tour.nodes) ? tour.nodes : []).find((row: FirebaseFirestore.DocumentData) => Number(row?.id) === nodeId);
  const expectedOriginal = `tours/originals/${uid}/${tourId}/`;
  if (!node || typeof node.original_path !== "string" || !node.original_path.startsWith(expectedOriginal)) {
    throw new HttpsError("not-found", "The owner panorama viewpoint was not found.");
  }
  const mediaRef = db.collection("mediaAssets").doc(`${uid}_${data.assetId}`);
  const mediaSnap = await mediaRef.get();
  const media = mediaSnap.data();
  if (!mediaSnap.exists || media?.uid !== uid || media.mediaType !== "panorama" || media.originalPath !== node.original_path ||
      media.linkedTourId !== tourId || !["awaiting-privacy-processing", "privacy-derivative-ready"].includes(String(media.status))) {
    throw new HttpsError("failed-precondition", "The original panorama is not linked to this owner viewpoint.");
  }
  const original = await r2Head(node.original_path);
  if (!original || original.key !== node.original_path || original.uid !== uid || original.mediaType !== "panorama" ||
      original.contentType !== "image/jpeg" || original.size <= 0 || original.size > MAX_PANORAMA_BYTES) {
    throw new HttpsError("failed-precondition", "The private original JPEG could not be verified.");
  }
  await consumeRateLimit(uid, "panoramaDerivativeUpload", 20, 60 * 60 * 1000);

  const revisionId = randomUUID().replace(/-/g, "");
  const reservationId = randomUUID();
  const objectKey = `tours/derivatives/${uid}/${tourId}/${nodeId}/${revisionId}_${data.derivativeSha256}.jpg`;
  const expiresAtSeconds = Math.floor(Date.now() / 1000) + UPLOAD_TOKEN_TTL_MS / 1000;
  const expiresAt = Timestamp.fromMillis(expiresAtSeconds * 1000 + UPLOAD_IN_FLIGHT_GRACE_MS);
  await reserveStorageBytes({
    reservationId,
    uid,
    assetId: data.assetId,
    mediaType: "panorama",
    objectKey,
    reservedBytes: Number(data.expectedBytes),
    purpose: "processed",
    tourId,
  }, expiresAt);
  await db.collection("uploadReservations").doc(reservationId).set({
    nodeId,
    revisionId,
    derivativeSha256: data.derivativeSha256,
    processingVersion: data.processingVersion,
    originalPath: node.original_path,
  }, { merge: true });
  const uploadToken = signGatewayToken({
    scope: "upload",
    objectKey,
    contentType: "image/jpeg",
    maxBytes: Number(data.expectedBytes),
    mediaType: "panorama-derivative",
    assetId: data.assetId,
    tourId,
    nodeId,
    revisionId,
    derivativeSha256: data.derivativeSha256,
    exp: expiresAtSeconds,
  }, uid, reservationId);
  return {
    reservationId,
    objectKey,
    uploadUrl: r2UploadUrl(reservationId),
    uploadToken,
    expiresAt: new Date(expiresAtSeconds * 1000).toISOString(),
  };
});

/** Independently inspect and hash the Worker-stored bytes before quota finalization or review eligibility. */
export const finalizePanoramaDerivativeUpload = onCall(CALLABLE_OPTIONS, async (request) => {
  const uid = requireUid(request);
  const data = objectData(request.data, "Panorama derivative finalization");
  if (typeof data.reservationId !== "string" || !/^[A-Za-z0-9_-]{16,128}$/.test(data.reservationId)) {
    throw new HttpsError("invalid-argument", "A valid derivative reservation ID is required.");
  }
  const reservationRef = db.collection("uploadReservations").doc(data.reservationId);
  const reservationSnap = await reservationRef.get();
  if (!reservationSnap.exists) throw new HttpsError("not-found", "The derivative reservation was not found.");
  const reservation = reservationSnap.data()!;
  if (reservation.uid !== uid || reservation.mediaType !== "panorama" || reservation.purpose !== "processed") {
    throw new HttpsError("permission-denied", "This derivative reservation does not belong to your account.");
  }
  const parsed = /^tours\/derivatives\/([A-Za-z0-9_-]{1,128})\/([1-9][0-9]{0,15})\/([1-9][0-9]{0,15})\/([A-Za-z0-9_-]{16,64})_([a-f0-9]{64})\.jpg$/.exec(String(reservation.objectKey));
  if (!parsed || parsed[1] !== uid || Number(parsed[2]) !== Number(reservation.tourId) ||
      Number(parsed[3]) !== Number(reservation.nodeId) || parsed[4] !== reservation.revisionId || parsed[5] !== reservation.derivativeSha256) {
    throw new HttpsError("data-loss", "The derivative reservation key is inconsistent.");
  }
  const object = await r2Head(reservation.objectKey);
  if (!object) {
    if (reservation.status === "reserved") await releaseStorageReservation(data.reservationId, "derivative-object-missing");
    throw new HttpsError("not-found", "The uploaded derivative was not found.");
  }
  if (object.key !== reservation.objectKey || object.reservationId !== data.reservationId || object.uid !== uid ||
      object.mediaType !== "panorama-derivative") {
    throw new HttpsError("failed-precondition", "The stored object is not owned by this derivative reservation.");
  }
  const bytes = await r2Read(reservation.objectKey);
  let verified: ReturnType<typeof verifyStoredPanoramaDerivative>;
  try {
    verified = verifyStoredPanoramaDerivative({
      uid,
      tourId: Number(reservation.tourId),
      nodeId: Number(reservation.nodeId),
      revisionId: String(reservation.revisionId),
      reservationId: data.reservationId,
      expectedSha256: String(reservation.derivativeSha256),
      maxBytes: Number(reservation.reservedBytes),
      head: object,
      bytes,
    });
  } catch (error) {
    if (reservation.status === "completed") {
      await deleteStoredObject(reservation.objectKey, uid, "derivative-content-verification-failed");
    } else {
      await r2Delete(reservation.objectKey);
      if (await r2Head(reservation.objectKey)) throw new HttpsError("unavailable", "An invalid derivative could not be removed safely.");
      await releaseStorageReservation(data.reservationId, "derivative-content-verification-failed");
    }
    throw error;
  }
  const actualDigest = verified.sha256;
  await completeStorageReservation(data.reservationId, verified.actualBytes);

  const mediaRef = db.collection("mediaAssets").doc(`${uid}_${reservation.assetId}`);
  const revisionRef = mediaRef.collection("derivatives").doc(reservation.revisionId);
  const tours = await db.collection("tours").where("numericId", "==", Number(reservation.tourId)).limit(1).get();
  if (tours.empty) throw new HttpsError("not-found", "Tour was not found after derivative accounting finalized.");
  const tourRef = tours.docs[0].ref;
  const storeMatches = await db.collection("stores").where("numericId", "==", tours.docs[0].data().storeId).limit(1).get();
  if (storeMatches.empty) throw new HttpsError("not-found", "Store was not found after derivative accounting finalized.");
  const storeRef = storeMatches.docs[0].ref;
  const verifiedAt = Timestamp.now();
  const verifiedDerivative = {
    status: "verified",
    objectKey: reservation.objectKey,
    size: verified.actualBytes,
    contentType: "image/jpeg",
    sha256: actualDigest,
    revisionId: reservation.revisionId,
    processingVersion: reservation.processingVersion,
    reservationId: data.reservationId,
    accountingState: "counted",
    verifiedAt,
  };
  await db.runTransaction(async (transaction) => {
    const [tourSnapshot, storeSnapshot, mediaSnapshot] = await Promise.all([
      transaction.get(tourRef), transaction.get(storeRef), transaction.get(mediaRef),
    ]);
    const tour = tourSnapshot.data();
    const store = storeSnapshot.data();
    const media = mediaSnapshot.data();
    if (!tourSnapshot.exists || !tour || !storeSnapshot.exists || !store || !mediaSnapshot.exists || !media) {
      throw new HttpsError("not-found", "The owner tour or original media record was not found.");
    }
    if (tour.status !== "draft" || tour.ownerUid !== uid || store.ownerUid !== uid || store.status !== "approved" ||
        media.uid !== uid || media.originalPath !== reservation.originalPath || media.linkedTourId !== Number(reservation.tourId)) {
      throw new HttpsError("permission-denied", "The derivative no longer belongs to this owner's draft tour.");
    }
    if (!Array.isArray(tour.nodes)) throw new HttpsError("data-loss", "Tour viewpoint data is invalid.");
    const nodes = tour.nodes as FirebaseFirestore.DocumentData[];
    const index = nodes.findIndex((row) => Number(row?.id) === Number(reservation.nodeId));
    if (index < 0 || nodes[index].original_path !== reservation.originalPath) {
      throw new HttpsError("failed-precondition", "The panorama viewpoint changed after derivative reservation.");
    }
    transaction.set(revisionRef, {
      ...verifiedDerivative,
      uid,
      assetId: reservation.assetId,
      tourId: Number(reservation.tourId),
      nodeId: Number(reservation.nodeId),
      processingVersion: reservation.processingVersion,
      createdAt: verifiedAt,
    }, { merge: true });
    const current = nodes[index].verified_derivative;
    const reservationCreatedAt = reservation.createdAt instanceof Timestamp ? reservation.createdAt.toMillis() : 0;
    const currentVerifiedAt = current?.verifiedAt instanceof Timestamp ? current.verifiedAt.toMillis() : 0;
    if (current?.status === "verified" && current.revisionId !== reservation.revisionId && currentVerifiedAt > reservationCreatedAt) {
      return;
    }
    const nextNode = { ...nodes[index] };
    delete nextNode.owner_review;
    nodes[index] = {
      ...nextNode,
      verified_derivative: verifiedDerivative,
      privacy_status: "awaiting-owner-review",
      owner_reviewed: false,
      image: "",
    };
    transaction.update(tourRef, { nodes, updatedAt: verifiedAt });
    transaction.set(mediaRef, {
      latestDerivativeRevisionId: reservation.revisionId,
      latestDerivativeObjectKey: reservation.objectKey,
      latestDerivativeSha256: actualDigest,
      updatedAt: verifiedAt,
    }, { merge: true });
  });
  return {
    status: "verified",
    objectKey: reservation.objectKey,
    size: verified.actualBytes,
    contentType: "image/jpeg",
    sha256: actualDigest,
    revisionId: reservation.revisionId,
    reservationId: data.reservationId,
    accountingState: "counted",
  };
});

export const deleteMediaAsset = onCall(CALLABLE_OPTIONS, async (request) => {
  const uid = requireUid(request);
  await consumeRateLimit(uid, "mediaDelete", 30, 60 * 60 * 1000);
  const data = objectData(request.data, "Media deletion details");
  if (typeof data.assetId !== "string" || !/^[A-Za-z0-9_-]{1,100}$/.test(data.assetId)) {
    throw new HttpsError("invalid-argument", "A valid media ID is required.");
  }
  const mediaRef = db.collection("mediaAssets").doc(`${uid}_${data.assetId}`);
  const mediaSnap = await mediaRef.get();
  if (!mediaSnap.exists) {
    const admin = await db.collection("users").doc(uid).get();
    if (admin.data()?.role !== "admin") throw new HttpsError("not-found", "Media was not found.");
    const matching = await db.collection("mediaAssets").where("assetId", "==", data.assetId).limit(1).get();
    if (matching.empty) throw new HttpsError("not-found", "Media was not found.");
    return deleteMediaRecord(matching.docs[0].ref, uid);
  }
  return deleteMediaRecord(mediaRef, uid);
});

export const getPrivateMediaAccess = onCall(CALLABLE_OPTIONS, async (request) => {
  const uid = requireUid(request);
  const data = objectData(request.data, "Private media access details");
  if (typeof data.assetId !== "string" || !/^[A-Za-z0-9_-]{1,100}$/.test(data.assetId)) {
    throw new HttpsError("invalid-argument", "A valid media ID is required.");
  }
  const caller = await db.collection("users").doc(uid).get();
  if (!caller.exists) throw new HttpsError("permission-denied", "This account is no longer active.");
  const isAdmin = caller.data()?.role === "admin";
  const targetUid = isAdmin && typeof data.uid === "string" ? data.uid : uid;
  const media = await db.collection("mediaAssets").doc(`${targetUid}_${data.assetId}`).get();
  if (!media.exists) throw new HttpsError("not-found", "Private media was not found.");
  const record = media.data()!;
  if (!isAdmin && record.uid !== uid) throw new HttpsError("permission-denied", "You cannot view this media.");
  if (!new Set(["store", "panorama"]).has(String(record.mediaType))) {
    throw new HttpsError("failed-precondition", "This media is not private.");
  }
  const objectKey = record.mediaType === "panorama" ? record.originalPath : record.privatePath;
  if (typeof objectKey !== "string" || !["ready", "awaiting-privacy-processing"].includes(String(record.status))) {
    throw new HttpsError("failed-precondition", "Private media is not ready to view.");
  }
  const token = signGatewayToken({ scope: "media:read", objectKey }, uid);
  return { url: r2PrivateMediaUrl(objectKey), token };
});

async function claimMediaDeletion(mediaRef: FirebaseFirestore.DocumentReference, actorUid: string) {
  return db.runTransaction(async (transaction) => {
    const current = await transaction.get(mediaRef);
    if (!current.exists) throw new HttpsError("not-found", "Media was not found.");
    const media = current.data()!;
    if (media.uid !== actorUid) {
      const admin = await transaction.get(db.collection("users").doc(actorUid));
      if (admin.data()?.role !== "admin") throw new HttpsError("permission-denied", "You cannot delete this media.");
    }
    if (media.linkedProductId != null || media.linkedStoreId != null || media.linkedTourId != null) {
      throw new HttpsError("failed-precondition", "Remove this media from its product, store, or tour before deleting it.");
    }
    const now = Timestamp.now();
    transaction.update(mediaRef, { status: "deleting", deletionStartedAt: now, updatedAt: now });
    return media;
  });
}

async function deleteMediaRecord(mediaRef: FirebaseFirestore.DocumentReference, actorUid: string) {
  // Re-read ownership and links transactionally before claiming deletion so a
  // concurrent product, store, or tour link cannot be deleted from stale state.
  const media = await claimMediaDeletion(mediaRef, actorUid);
  const objectKeys = [
    media.objectKey,
    media.quarantinePath,
    media.publicPath,
    media.privatePath,
    media.originalPath,
    media.pendingOutputPath,
    media.pendingPublicPath,
  ].filter((key): key is string => typeof key === "string");
  const derivativeRecords = await mediaRef.collection("derivatives").get();
  for (const derivative of derivativeRecords.docs) {
    const key = derivative.data().objectKey;
    if (typeof key === "string") objectKeys.push(key);
  }
  const uniqueObjectKeys = [...new Set(objectKeys)];
  for (const objectKey of uniqueObjectKeys) await deleteStoredObject(objectKey, actorUid, "user-request");
  for (const derivative of derivativeRecords.docs) {
    await derivative.ref.set({ status: "deleted", accountingState: "deleted", deletedAt: Timestamp.now() }, { merge: true });
  }
  await mediaRef.set({ status: "deleted", accountingState: "deleted", deletedAt: Timestamp.now(), updatedAt: Timestamp.now() }, { merge: true });
  return { ok: true, assetId: media.assetId };
}

export const cleanupAbandonedMediaReservations = onCall(CALLABLE_OPTIONS, async (request) => {
  const uid = requireUid(request);
  const profile = await db.collection("users").doc(uid).get();
  if (profile.data()?.role !== "admin") throw new HttpsError("permission-denied", "Administrator access is required.");
  const expired = await db.collection("uploadReservations")
    .where("status", "==", "reserved")
    .where("expiresAt", "<=", Timestamp.now())
    .limit(100)
    .get();
  let cleaned = 0;
  for (const reservation of expired.docs) {
    await expireReservation(reservation.id);
    cleaned++;
  }
  return { cleaned };
});

export async function expireReservation(reservationId: string): Promise<void> {
  const ref = db.collection("uploadReservations").doc(reservationId);
  const snapshot = await ref.get();
  if (!snapshot.exists || snapshot.data()?.status !== "reserved") return;
  const data = snapshot.data()!;
  const expiresAt = data.expiresAt;
  if (!(expiresAt instanceof Timestamp) || expiresAt.toMillis() > Date.now()) return;
  const object = await r2Head(String(data.objectKey));
  if (object && (object.reservationId !== reservationId || object.uid !== data.uid || object.size > Number(data.reservedBytes))) {
    await r2Delete(object.key);
    if (await r2Head(object.key)) throw new HttpsError("unavailable", "An invalid abandoned upload could not be removed.");
  } else if (object) {
    await r2Delete(object.key);
    if (await r2Head(object.key)) throw new HttpsError("unavailable", "An abandoned upload could not be removed.");
  }
  await releaseStorageReservation(reservationId, "expired-or-abandoned");
  if (data.purpose === "upload") {
    await db.collection("mediaAssets").doc(`${data.uid}_${data.assetId}`).set({
      status: "expired",
      accountingState: "deleted",
      expiredAt: Timestamp.now(),
      updatedAt: Timestamp.now(),
    }, { merge: true });
  }
}
