import { Timestamp } from "firebase-admin/firestore";
import { getStorage } from "firebase-admin/storage";
import { HttpsError, onCall } from "firebase-functions/v2/https";
import { db, objectData } from "./admin";
import { enforceCallableAppCheck } from "./callable_options";

const CALLABLE_OPTIONS = { region: "asia-southeast1", enforceAppCheck: enforceCallableAppCheck };

function requireUid(request: { auth?: { uid: string } | null }): string {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Sign in to continue.");
  return uid;
}

function tourPayload(tour: FirebaseFirestore.DocumentData) {
  return {
    id: tour.numericId,
    store_id: tour.storeId,
    title: tour.title,
    status: tour.status,
    nodes: tour.nodes ?? [],
  };
}

async function nextTourId(): Promise<number> {
  const sequence = db.collection("systemCounters").doc("tourIds");
  return db.runTransaction(async (transaction) => {
    const counter = await transaction.get(sequence);
    let nextId: number;
    if (counter.exists) {
      nextId = Number(counter.data()?.value ?? 0) + 1;
    } else {
      const highest = await transaction.get(db.collection("tours").orderBy("numericId", "desc").limit(1));
      nextId = Number(highest.docs[0]?.data().numericId ?? 0) + 1;
    }
    transaction.set(sequence, { value: nextId });
    return nextId;
  });
}

async function verifyStoreAccess(uid: string, storeId: number): Promise<void> {
  const [stores, user] = await Promise.all([
    db.collection("stores").where("numericId", "==", storeId).limit(1).get(),
    db.collection("users").doc(uid).get(),
  ]);
  if (stores.empty || !user.exists) throw new HttpsError("not-found", "Store was not found.");
  const store = stores.docs[0].data();
  if (store.status !== "approved") throw new HttpsError("failed-precondition", "Only approved stores can create tours.");
  if (store.ownerUid !== uid && user.data()?.role !== "admin") {
    throw new HttpsError("permission-denied", "Only the store owner or an administrator can edit this tour.");
  }
}

function safeNodes(value: unknown): FirebaseFirestore.DocumentData[] {
  if (!Array.isArray(value) || value.length > 40 || value.some((node) => !node || typeof node !== "object")) {
    throw new HttpsError("failed-precondition", "Tour draft structure is invalid.");
  }
  return value as FirebaseFirestore.DocumentData[];
}

/** The callable accepts only draft structure. Processing/review/publication fields are server-owned. */
export const manageStoreTour = onCall(CALLABLE_OPTIONS, async (request) => {
  const uid = requireUid(request);
  const data = objectData(request.data, "Tour details");
  const action = data.action;

  if (action === "create") {
    const storeId = data.storeId;
    if (typeof storeId !== "number" || !Number.isSafeInteger(storeId) || storeId <= 0) {
      throw new HttpsError("invalid-argument", "A valid store ID is required.");
    }
    if (typeof data.title !== "string" || !data.title.trim() || data.title.trim().length > 80) {
      throw new HttpsError("invalid-argument", "Tour title must be between 1 and 80 characters.");
    }
    await verifyStoreAccess(uid, storeId);
    // A callable may commit successfully while its response is lost. Reuse the
    // owner's existing draft for this store so a client retry cannot create a
    // duplicate draft or allocate another numeric tour ID.
    const existingDraft = await db.collection("tours")
      .where("storeId", "==", storeId)
      .where("ownerUid", "==", uid)
      .where("status", "==", "draft")
      .limit(1)
      .get();
    if (!existingDraft.empty) return tourPayload(existingDraft.docs[0].data());
    const numericId = await nextTourId();
    const payload = { numericId, storeId, title: data.title.trim(), status: "draft", nodes: [], ownerUid: uid };
    await db.collection("tours").add(payload);
    return tourPayload(payload);
  }

  const tourId = data.tourId;
  if (typeof tourId !== "number" || !Number.isSafeInteger(tourId) || tourId <= 0) {
    throw new HttpsError("invalid-argument", "A valid tour ID is required.");
  }
  const matches = await db.collection("tours").where("numericId", "==", tourId).limit(1).get();
  if (matches.empty) throw new HttpsError("not-found", "Tour was not found.");
  const tourRef = matches.docs[0].ref;
  const initialTour = matches.docs[0].data();
  const storeMatches = await db.collection("stores").where("numericId", "==", initialTour.storeId).limit(1).get();
  if (storeMatches.empty) throw new HttpsError("not-found", "Store was not found.");
  const storeRef = storeMatches.docs[0].ref;
  const userRef = db.collection("users").doc(uid);
  let newNodeTitle: string | undefined;
  let newNodePath: string | undefined;
  if (action === "addNode") {
    if (typeof data.title !== "string" || !data.title.trim() || data.title.trim().length > 80) {
      throw new HttpsError("invalid-argument", "Viewpoint title must be between 1 and 80 characters.");
    }
    if (typeof data.originalPath !== "string" ||
        !new RegExp(`^tours/originals/${uid}/${tourId}/[A-Za-z0-9_-]+$`).test(data.originalPath)) {
      throw new HttpsError("invalid-argument", "A private original uploaded to this tour is required.");
    }
    const original = getStorage().bucket().file(data.originalPath);
    const [exists] = await original.exists();
    if (!exists) throw new HttpsError("failed-precondition", "The panorama upload could not be found. Upload it again.");
    const [metadata] = await original.getMetadata();
    const size = Number(metadata.size ?? 0);
    if (size <= 0 || size > 50 * 1024 * 1024 ||
        !["image/jpeg", "image/png", "image/webp"].includes(metadata.contentType ?? "")) {
      throw new HttpsError("failed-precondition", "The uploaded panorama failed size or type validation.");
    }
    newNodeTitle = data.title.trim();
    newNodePath = data.originalPath;
  }
  if (action === "connect" && (!Number.isSafeInteger(data.fromNodeId) || !Number.isSafeInteger(data.toNodeId) || data.fromNodeId === data.toNodeId)) {
    throw new HttpsError("invalid-argument", "Choose two different viewpoints.");
  }
  let result: FirebaseFirestore.DocumentData | undefined;
  await db.runTransaction(async (transaction) => {
    const [snapshot, storeSnapshot, userSnapshot] = await Promise.all([
      transaction.get(tourRef),
      transaction.get(storeRef),
      transaction.get(userRef),
    ]);
    const tour = snapshot.data();
    const store = storeSnapshot.data();
    const role = userSnapshot.data()?.role;
    if (!snapshot.exists || !tour || !storeSnapshot.exists || !store || !userSnapshot.exists) {
      throw new HttpsError("not-found", "Tour or store was not found.");
    }
    if (tour.status !== "draft") throw new HttpsError("failed-precondition", "Only draft tours can be edited.");
    if (Number(store.numericId) !== Number(tour.storeId) || store.status !== "approved") {
      throw new HttpsError("failed-precondition", "Only tours for approved stores can be edited.");
    }
    const isAdmin = role === "admin";
    if (!isAdmin && store.ownerUid !== uid) {
      throw new HttpsError("permission-denied", "Only the store owner or an administrator can edit this tour.");
    }
    if (!isAdmin && tour.ownerUid !== uid) {
      throw new HttpsError("permission-denied", "Only the tour owner or an administrator can edit this draft.");
    }
    const nodes = safeNodes(tour.nodes ?? []);

    if (action === "addNode") {
      if (nodes.length >= 40) throw new HttpsError("failed-precondition", "A tour can contain at most 40 viewpoints.");
      const nodeId = nodes.reduce((max, node) => Math.max(max, Number(node.id) || 0), 0) + 1;
      const previous = nodes.length ? nodes[nodes.length - 1] : null;
      const node = {
        id: nodeId,
        title: newNodeTitle!,
        image: "",
        original_path: newNodePath!,
        connections: previous ? [Number(previous.id)] : [],
        privacy_status: "processing",
        owner_reviewed: false,
        manual_blur: false,
        original_retained: true,
        blur_regions: [],
      };
      if (previous) {
        const previousIndex = nodes.length - 1;
        nodes[previousIndex] = { ...previous, connections: [...new Set([...(Array.isArray(previous.connections) ? previous.connections : []), nodeId])] };
      }
      nodes.push(node);
    } else if (action === "connect") {
      const from = data.fromNodeId;
      const to = data.toNodeId;
      if (!Number.isSafeInteger(from) || !Number.isSafeInteger(to) || from === to) {
        throw new HttpsError("invalid-argument", "Choose two different viewpoints.");
      }
      const fromNode = nodes.find((node) => node.id === from);
      const toNode = nodes.find((node) => node.id === to);
      if (!fromNode || !toNode) throw new HttpsError("not-found", "A selected viewpoint was not found.");
      fromNode.connections = [...new Set([...(Array.isArray(fromNode.connections) ? fromNode.connections : []), to])];
      toNode.connections = [...new Set([...(Array.isArray(toNode.connections) ? toNode.connections : []), from])];
    } else {
      throw new HttpsError("invalid-argument", "This tour action is not available.");
    }
    transaction.update(tourRef, { nodes, updatedAt: Timestamp.now() });
    result = { ...tour, nodes };
  });
  return tourPayload(result!);
});
