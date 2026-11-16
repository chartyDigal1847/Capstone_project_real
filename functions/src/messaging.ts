import { Timestamp } from "firebase-admin/firestore";
import { HttpsError, onCall } from "firebase-functions/v2/https";
import { consumeRateLimit, db } from "./admin";
import { enforceCallableAppCheck } from "./callable_options";

const CALLABLE_OPTIONS = { region: "asia-southeast1", enforceAppCheck: enforceCallableAppCheck };

function callerUid(request: { auth?: { uid: string } | null }): string {
  if (!request.auth?.uid) throw new HttpsError("unauthenticated", "Sign in to continue.");
  return request.auth.uid;
}

function messageText(value: unknown): string {
  if (typeof value !== "string") throw new HttpsError("invalid-argument", "Message text is required.");
  const result = value.trim();
  if (!result || result.length > 1000) {
    throw new HttpsError("invalid-argument", "Message must be between 1 and 1000 characters.");
  }
  return result;
}

export const sendStoreMessage = onCall(CALLABLE_OPTIONS, async (request) => {
  const uid = callerUid(request);
  const storeId = request.data?.storeId;
  if (typeof storeId !== "number" || !Number.isSafeInteger(storeId) || storeId <= 0) {
    throw new HttpsError("invalid-argument", "A valid store is required.");
  }
  const message = messageText(request.data?.text);
  const [userSnapshot, storeSnapshot] = await Promise.all([
    db.collection("users").doc(uid).get(),
    db.collection("stores").where("numericId", "==", storeId).limit(1).get(),
  ]);
  if (!userSnapshot.exists) throw new HttpsError("failed-precondition", "Your account profile is not ready yet.");
  if (userSnapshot.data()?.role !== "customer") {
    throw new HttpsError("permission-denied", "Only customers can contact store owners.");
  }
  if (storeSnapshot.empty || storeSnapshot.docs[0].data().status !== "approved") {
    throw new HttpsError("not-found", "That store is not available.");
  }
  const store = storeSnapshot.docs[0].data();
  const ownerUid = String(store.ownerUid ?? "");
  if (!ownerUid) throw new HttpsError("failed-precondition", "This store has no active owner account.");
  await consumeRateLimit(uid, "storeMessage", 20, 24 * 60 * 60 * 1000);
  const user = userSnapshot.data()!;
  const ref = await db.collection("messages").add({
    storeId,
    storeName: String(store.name ?? "Store"),
    senderUid: uid,
    senderName: String(user.name ?? "Customer"),
    senderEmail: String(user.email ?? ""),
    recipientUid: ownerUid,
    text: message,
    createdAt: Timestamp.now(),
    read: false,
  });
  return { ok: true, id: ref.id };
});

export const listStoreMessages = onCall(CALLABLE_OPTIONS, async (request) => {
  const uid = callerUid(request);
  const profile = await db.collection("users").doc(uid).get();
  if (!profile.exists) throw new HttpsError("failed-precondition", "Your account profile is not ready yet.");
  const role = profile.data()?.role;
  const query = role === "owner"
    ? db.collection("messages").where("recipientUid", "==", uid).limit(100)
    : db.collection("messages").where("senderUid", "==", uid).limit(100);
  const snapshot = await query.get();
  const messages = snapshot.docs.map((doc) => {
    const data = doc.data();
    const createdAt = data.createdAt instanceof Timestamp ? data.createdAt.toDate().toISOString() : new Date().toISOString();
    return { id: doc.id, ...data, createdAt };
  });
  messages.sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt)));
  return { messages };
});
