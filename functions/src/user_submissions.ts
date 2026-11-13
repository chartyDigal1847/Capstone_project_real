import { HttpsError, onCall } from "firebase-functions/v2/https";
import { consumeRateLimit, db, objectData } from "./admin";
import { enforceCallableAppCheck } from "./callable_options";
import { nextId } from "./listings";

const CALLABLE_OPTIONS = { region: "asia-southeast1", enforceAppCheck: enforceCallableAppCheck };
const SUBMISSION_WINDOW_MS = 24 * 60 * 60 * 1000;

function callerUid(request: { auth?: { uid: string } | null }): string {
  if (!request.auth?.uid) throw new HttpsError("unauthenticated", "Sign in to continue.");
  return request.auth.uid;
}

function requiredText(value: unknown, field: string, limit: number): string {
  if (typeof value !== "string") throw new HttpsError("invalid-argument", `${field} must be text.`);
  const normalized = value.trim();
  if (!normalized || normalized.length > limit) {
    throw new HttpsError("invalid-argument", `${field} must be between 1 and ${limit} characters.`);
  }
  return normalized;
}

async function profileFor(uid: string): Promise<FirebaseFirestore.DocumentData> {
  const profile = await db.collection("users").doc(uid).get();
  if (!profile.exists || !Number.isSafeInteger(profile.data()?.numericId) || Number(profile.data()?.numericId) <= 0) {
    throw new HttpsError("failed-precondition", "Your account profile is not ready yet.");
  }
  return profile.data()!;
}

export const submitUserFeedback = onCall(CALLABLE_OPTIONS, async (request) => {
  const uid = callerUid(request);
  const data = objectData(request.data, "Feedback details");
  const topic = requiredText(data.topic, "Topic", 80);
  const body = requiredText(data.body, "Feedback", 1000);
  const area = data.area == null ? "" : typeof data.area === "string" ? data.area.trim() : null;
  if (area == null || area.length > 120) {
    throw new HttpsError("invalid-argument", "Area must be 120 characters or fewer.");
  }
  const user = await profileFor(uid);
  await consumeRateLimit(uid, "userFeedback", 5, SUBMISSION_WINDOW_MS);
  const numericId = await nextId("feedback", "feedbackIds");
  await db.collection("feedback").add({
    numericId,
    userId: user.numericId,
    uid,
    topic,
    body,
    ...(area ? { area } : {}),
  });
  return { ok: true, id: numericId };
});

export const submitUserReport = onCall(CALLABLE_OPTIONS, async (request) => {
  const uid = callerUid(request);
  const data = objectData(request.data, "Report details");
  const target = requiredText(data.target, "Report target", 120);
  const reason = requiredText(data.reason, "Report reason", 400);
  const user = await profileFor(uid);
  await consumeRateLimit(uid, "userReport", 10, SUBMISSION_WINDOW_MS);
  const numericId = await nextId("reports", "reportIds");
  await db.collection("reports").add({
    numericId,
    userId: user.numericId,
    uid,
    target,
    reason,
    resolved: false,
  });
  return { ok: true, id: numericId };
});
