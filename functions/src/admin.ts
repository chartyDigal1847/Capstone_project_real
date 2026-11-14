import { getApps, initializeApp } from "firebase-admin/app";
import { getFirestore, Timestamp } from "firebase-admin/firestore";
import { HttpsError } from "firebase-functions/v2/https";

if (getApps().length === 0) initializeApp();

export const db = getFirestore();

export function objectData(value: unknown, label: string): Record<string, unknown> {
  if (value == null || typeof value !== "object" || Array.isArray(value)) {
    throw new HttpsError("invalid-argument", `${label} must be an object.`);
  }
  return value as Record<string, unknown>;
}

export async function consumeRateLimit(
  uid: string,
  operation: string,
  maximum: number,
  windowMs: number,
): Promise<void> {
  const ref = db.collection("systemRateLimits").doc(`${uid}_${operation}`);
  const now = Timestamp.now();
  await db.runTransaction(async (transaction) => {
    const current = await transaction.get(ref);
    const storedStart = current.data()?.windowStartedAt;
    const elapsed = storedStart instanceof Timestamp ? now.toMillis() - storedStart.toMillis() : null;
    const inWindow = elapsed != null && elapsed >= 0 && elapsed < windowMs;
    const count = inWindow ? Number(current.data()?.count ?? 0) : 0;
    if (count >= maximum) {
      throw new HttpsError("resource-exhausted", "You have reached the request limit. Try again later.");
    }
    transaction.set(ref, {
      uid,
      operation,
      windowStartedAt: inWindow ? storedStart : now,
      count: count + 1,
      updatedAt: now,
    });
  });
}
