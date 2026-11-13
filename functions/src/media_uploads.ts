import { randomUUID } from "node:crypto";
import { getStorage } from "firebase-admin/storage";
import { FieldValue } from "firebase-admin/firestore";
import { onObjectFinalized } from "firebase-functions/v2/storage";
import * as logger from "firebase-functions/logger";
import { db } from "./admin";
import { FORMATS, MAX_BYTES, stripImageMetadata } from "./image_sanitizer";

const FUNCTION_REGION = "asia-southeast1";
/** Validate a UID-scoped image, then publish a catalog image or store a private processed copy. */
export const processUploadedMedia = onObjectFinalized({ region: FUNCTION_REGION, retry: true }, async (event) => {
  const object = event.data;
  const match = /^(products|stores)\/quarantine\/([^/]+)\/([A-Za-z0-9_-]+)$/.exec(object.name ?? "");
  if (!match || !object.bucket) return;
  const [, mediaType, uid, assetId] = match;
  const mediaRef = db.collection("mediaAssets").doc(`${uid}_${assetId}`);
  const previous = await mediaRef.get();
  if (previous.data()?.status === "ready" || previous.data()?.status === "failed") return;
  const source = getStorage().bucket(object.bucket).file(object.name!);
  const mediaKind = mediaType === "products" ? "product" : "store";
  const markFailed = async (reason: string) => mediaRef.set({
    uid,
    assetId,
    mediaType: mediaKind,
    status: "failed",
    reason,
    quarantinePath: object.name,
    updatedAt: FieldValue.serverTimestamp(),
  });
  const declaredSize = Number(object.size ?? 0);
  const format = FORMATS.find((candidate) => candidate.mime === object.contentType);

  if (!format || declaredSize <= 0 || declaredSize > MAX_BYTES) {
    await markFailed("unsupported-image");
    await source.delete({ ignoreNotFound: true });
    return;
  }

  const [bytes] = await source.download();
  if (bytes.length !== declaredSize || !format.signature(bytes)) {
    await markFailed("invalid-image-content");
    await source.delete({ ignoreNotFound: true });
    return;
  }
  const sanitized = stripImageMetadata(bytes, format.mime);
  if (!sanitized) {
    await markFailed("invalid-image-structure");
    await source.delete({ ignoreNotFound: true });
    return;
  }

  const profile = await db.collection("users").doc(uid).get();
  if (!profile.exists) {
    await markFailed("account-not-found");
    await source.delete({ ignoreNotFound: true });
    return;
  }

  const isProduct = mediaType === "products";
  const outputPath = isProduct
    ? `products/public/${uid}/${assetId}.${format.extension}`
    : `stores/processed/${uid}/${assetId}.${format.extension}`;
  const outputFile = getStorage().bucket(object.bucket).file(outputPath);
  const token = isProduct ? randomUUID() : undefined;
  await outputFile.save(sanitized, {
    resumable: false,
    metadata: {
      contentType: format.mime,
      cacheControl: isProduct ? "public,max-age=86400" : "private,max-age=0,no-store",
      metadata: { ...(token ? { firebaseStorageDownloadTokens: token } : {}), metadataStripped: "true" },
    },
  });
  const downloadUrl = token
    ? `https://firebasestorage.googleapis.com/v0/b/${object.bucket}/o/${encodeURIComponent(outputPath)}?alt=media&token=${token}`
    : undefined;
  await mediaRef.set({
    uid,
    assetId,
    mediaType: isProduct ? "product" : "store",
    status: "ready",
    quarantinePath: object.name,
    ...(isProduct ? { publicPath: outputPath, downloadUrl } : { privatePath: outputPath }),
    contentType: format.mime,
    size: sanitized.length,
    metadataStripped: true,
    updatedAt: FieldValue.serverTimestamp(),
  });
  await source.delete({ ignoreNotFound: true });
  logger.info("Processed uploaded image", { mediaType, bytes: sanitized.length });
});

/** Validate private panorama originals and queue them without implying they are sanitized. */
export const validatePanoramaUpload = onObjectFinalized(
  { region: FUNCTION_REGION, retry: true },
  async (event) => {
    const object = event.data;
    const match = /^tours\/originals\/([^/]+)\/(\d+)\/([A-Za-z0-9_-]+)$/.exec(object.name ?? "");
    if (!match || !object.bucket || !object.name) return;
    const [, uid, tourId, assetId] = match;
    const mediaRef = db.collection("mediaAssets").doc(`${uid}_${assetId}`);
    const previous = await mediaRef.get();
    if (["awaiting-privacy-processing", "processing", "ready", "failed"].includes(previous.data()?.status)) return;

    const source = getStorage().bucket(object.bucket).file(object.name);
    const declaredSize = Number(object.size ?? 0);
    const format = FORMATS.find((candidate) => candidate.mime === object.contentType);
    let failure: string | null = null;
    let bytes: Buffer | null = null;
    if (!format || declaredSize <= 0 || declaredSize > 50 * 1024 * 1024) {
      failure = "unsupported-image";
    } else {
      // Storage/network failures throw so the event retry policy can retry them.
      [bytes] = await source.download();
      if (bytes.length !== declaredSize || !format.signature(bytes)) failure = "invalid-image-content";
    }

    if (failure) {
      await mediaRef.set({
        uid,
        tourId: Number(tourId),
        assetId,
        mediaType: "panorama",
        status: "failed",
        reason: failure,
        originalPath: object.name,
        updatedAt: FieldValue.serverTimestamp(),
      }, { merge: true });
      await source.delete({ ignoreNotFound: true });
      logger.warn("Rejected invalid panorama original", { reason: failure });
      return;
    }

    await mediaRef.set({
      uid,
      tourId: Number(tourId),
      assetId,
      mediaType: "panorama",
      status: "awaiting-privacy-processing",
      originalPath: object.name,
      contentType: format!.mime,
      size: bytes!.length,
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });
    logger.info("Validated panorama; awaiting privacy processor", { mediaType: "panorama" });
  },
);
