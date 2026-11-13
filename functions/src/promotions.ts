import { Timestamp } from "firebase-admin/firestore";
import { HttpsError, onCall, type CallableRequest } from "firebase-functions/v2/https";
import { consumeRateLimit, db, objectData } from "./admin";
import { nextId, storeAndGrant } from "./listings";
import { enforceCallableAppCheck } from "./callable_options";

const CALLABLE_OPTIONS = { region: "asia-southeast1", enforceAppCheck: enforceCallableAppCheck };
const PROMOTION_STATUS = new Set(["approved", "rejected"]);
const PROMOTION_WINDOW_MS = 24 * 60 * 60 * 1000;
const MAX_PROMOTIONS_PER_WINDOW = 10;

function uidFor(request: { auth?: { uid: string } | null }): string {
  if (!request.auth?.uid) throw new HttpsError("unauthenticated", "Sign in to continue.");
  return request.auth.uid;
}

function text(value: unknown, field: string, maxLength: number): string {
  if (typeof value !== "string") throw new HttpsError("invalid-argument", `${field} must be text.`);
  const normalized = value.trim();
  if (normalized.length === 0 || normalized.length > maxLength) {
    throw new HttpsError("invalid-argument", `${field} is invalid.`);
  }
  return normalized;
}

export const createStorePromotion = onCall(CALLABLE_OPTIONS, async (request) => {
  const uid = uidFor(request);
  const data = objectData(request.data, "Promotion details");
  if (typeof data.storeId !== "number" || !Number.isSafeInteger(data.storeId) || data.storeId <= 0) {
    throw new HttpsError("invalid-argument", "A valid store ID is required.");
  }
  await storeAndGrant(uid, data.storeId, "promotions");
  const startsAt = text(data.starts_at, "starts_at", 64);
  const endsAt = text(data.ends_at, "ends_at", 64);
  const startMs = Date.parse(startsAt);
  const endMs = Date.parse(endsAt);
  if (!Number.isFinite(startMs) || !Number.isFinite(endMs) || startMs >= endMs) {
    throw new HttpsError("invalid-argument", "Promotion dates are invalid.");
  }
  await consumeRateLimit(uid, "storePromotion", MAX_PROMOTIONS_PER_WINDOW, PROMOTION_WINDOW_MS);
  const numericId = await nextId("promotions", "promotionIds");
  const promotionRef = db.collection("promotions").doc();
  await promotionRef.create({
    numericId,
    storeId: data.storeId,
    title: text(data.title, "title", 80),
    offer: text(data.offer, "offer", 200),
    starts_at: new Date(startMs).toISOString(),
    ends_at: new Date(endMs).toISOString(),
    sponsored: false,
    sponsoredRequested: data.sponsored === true,
    status: "pending",
    ownerUid: uid,
  });
  return { id: numericId, status: "pending" };
});

async function handlePromotionReview(request: CallableRequest<Record<string, unknown>>) {
  const adminUid = uidFor(request);
  const promotionId = request.data?.promotionId;
  const status = request.data?.status;
  if (typeof promotionId !== "number" || !Number.isSafeInteger(promotionId) || promotionId <= 0) {
    throw new HttpsError("invalid-argument", "A valid promotion ID is required.");
  }
  if (typeof status !== "string" || !PROMOTION_STATUS.has(status)) {
    throw new HttpsError("invalid-argument", "Promotion status is not supported.");
  }
  const admin = await db.collection("users").doc(adminUid).get();
  if (!admin.exists || admin.data()?.role !== "admin") {
    throw new HttpsError("permission-denied", "Administrator access is required.");
  }
  const matches = await db.collection("promotions").where("numericId", "==", promotionId).limit(1).get();
  if (matches.empty) throw new HttpsError("not-found", "Promotion was not found.");
  const promotionRef = matches.docs[0].ref;
  await db.runTransaction(async (transaction) => {
    const promotion = await transaction.get(promotionRef);
    const current = promotion.data();
    if (!promotion.exists) throw new HttpsError("not-found", "Promotion was not found.");
    if (current?.status === status) return;
    if (current?.status !== "pending") {
      throw new HttpsError("failed-precondition", "Only pending promotions can be reviewed.");
    }
    transaction.update(promotionRef, {
      status,
      sponsored: status === "approved" && current.sponsoredRequested === true,
    });
    transaction.create(db.collection("auditLogs").doc(), {
      action: `promotion.status.${status}`,
      promotionId,
      storeId: current.storeId,
      actorUid: adminUid,
      created_at: Timestamp.now().toDate().toISOString(),
    });
  });
  return { id: promotionId, status };
}

export const reviewStorePromotion = onCall(CALLABLE_OPTIONS, handlePromotionReview);
