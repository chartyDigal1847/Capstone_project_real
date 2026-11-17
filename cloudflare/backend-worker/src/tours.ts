import { documentData, FirestoreRest } from "./firestore.js";
import type { Env, Principal } from "./index.js";
import { ApiError } from "./errors.js";
import { gatewayHead } from "./r2_gateway_client.js";

async function body(request: Request): Promise<Record<string, unknown>> {
  try { const value: unknown = await request.json(); if (value && typeof value === "object" && !Array.isArray(value)) return value as Record<string, unknown>; }
  catch { /* bad JSON */ }
  throw new ApiError(400, "A valid JSON object is required.");
}

function tourPayload(tour: Record<string, unknown>) {
  return { id: tour.numericId, store_id: tour.storeId, title: tour.title, status: tour.status, nodes: tour.nodes ?? [] };
}

export async function handleTours(request: Request, env: Env, principal: Principal): Promise<Response> {
  if (request.method !== "POST") return Response.json({ error: "Method not allowed." }, { status: 405, headers: { Allow: "POST" } });
  const data = await body(request);
  const db = new FirestoreRest(env);
  const action = data.action;

  if (action === "create") {
    const storeId = data.storeId;
    if (!Number.isSafeInteger(storeId) || Number(storeId) <= 0) throw new ApiError(400, "A valid store ID is required.");
    if (typeof data.title !== "string" || !data.title.trim() || data.title.trim().length > 80) throw new ApiError(400, "Tour title must be between 1 and 80 characters.");
    const title = data.title.trim();
    const profile = documentData(await db.get(`users/${principal.uid}`));
    if (!profile) throw new ApiError(412, "Your account profile is not ready yet.");
    return await db.runTransaction(async (tx) => {
      const stores = await tx.query("stores", [{ field: "numericId", op: "EQUAL", value: Number(storeId) }], 1);
      if (!stores.length) throw new ApiError(404, "Store was not found.");
      const store = documentData(stores[0])!;
      if (store.status !== "approved") throw new ApiError(412, "Only approved stores can create tours.");
      if (store.ownerUid !== principal.uid && profile.role !== "admin") throw new ApiError(403, "Only the store owner or an administrator can edit this tour.");
      const drafts = await tx.query("tours", [
        { field: "storeId", op: "EQUAL", value: Number(storeId) },
        { field: "ownerUid", op: "EQUAL", value: principal.uid },
        { field: "status", op: "EQUAL", value: "draft" },
      ], 1);
      if (drafts.length) return Response.json(tourPayload(documentData(drafts[0])!));
      const counter = documentData(await tx.get("systemCounters/tourIds"));
      const highest = counter ? [] : await tx.query("tours", [], 1, [{ field: "numericId", direction: "DESCENDING" }]);
      const id = counter ? Number(counter.value ?? 0) + 1 : Number(documentData(highest[0] ?? null)?.numericId ?? 0) + 1;
      if (!Number.isSafeInteger(id) || id <= 0) throw new ApiError(503, "A tour ID could not be allocated safely.");
      const path = `tours/${crypto.randomUUID()}`;
      const tour = { numericId: id, storeId: Number(storeId), title, status: "draft", nodes: [], ownerUid: principal.uid };
      tx.set("systemCounters/tourIds", { value: id });
      tx.create(path, tour);
      return Response.json(tourPayload(tour));
    });
  }

  if (!Number.isSafeInteger(data.tourId) || Number(data.tourId) <= 0) throw new ApiError(400, "A valid tour ID is required.");
  const profile = documentData(await db.get(`users/${principal.uid}`));
  if (!profile) throw new ApiError(412, "Your account profile is not ready yet.");
  let newNodeTitle: string | undefined, newNodePath: string | undefined, panoramaMediaPath: string | undefined;
  if (action === "addNode") {
    if (typeof data.title !== "string" || !data.title.trim() || data.title.trim().length > 80) throw new ApiError(400, "Viewpoint title must be between 1 and 80 characters.");
    if (typeof data.originalPath !== "string" || !new RegExp(`^tours/originals/${principal.uid}/${Number(data.tourId)}/[A-Za-z0-9_-]+$`).test(data.originalPath)) throw new ApiError(400, "A private original uploaded to this tour is required.");
    const original = await gatewayHead(env, data.originalPath);
    if (!original) throw new ApiError(412, "The panorama upload could not be found. Upload it again.");
    if (original.size <= 0 || original.size > 50 * 1024 * 1024 || !["image/jpeg", "image/png", "image/webp"].includes(original.contentType)) throw new ApiError(412, "The uploaded panorama failed size or type validation.");
    newNodeTitle = data.title.trim();
    newNodePath = data.originalPath;
    panoramaMediaPath = `mediaAssets/${principal.uid}_${data.originalPath.split("/").at(-1)}`;
  }
  return await db.runTransaction(async (tx) => {
    const matches = await tx.query("tours", [{ field: "numericId", op: "EQUAL", value: Number(data.tourId) }], 1);
    if (!matches.length) throw new ApiError(404, "Tour was not found.");
    const tourDoc = matches[0];
    const tourPath = tourDoc.name.split("/documents/")[1];
    const tour = documentData(tourDoc)!;
    const stores = await tx.query("stores", [{ field: "numericId", op: "EQUAL", value: Number(tour.storeId) }], 1);
    if (!stores.length) throw new ApiError(404, "Store was not found.");
    const store = documentData(stores[0])!;
    if (tour.status !== "draft") throw new ApiError(412, "Only draft tours can be edited.");
    if (store.status !== "approved" || Number(store.numericId) !== Number(tour.storeId)) throw new ApiError(412, "Only tours for approved stores can be edited.");
    if ((!profile || profile.role !== "admin") && (store.ownerUid !== principal.uid || tour.ownerUid !== principal.uid)) throw new ApiError(403, "Only the tour owner or an administrator can edit this draft.");
    if (!Array.isArray(tour.nodes) || tour.nodes.length > 40 || tour.nodes.some((node) => !node || typeof node !== "object")) throw new ApiError(412, "Tour draft structure is invalid.");
    const nodes = tour.nodes as Array<Record<string, unknown>>;
    let panoramaMedia: Record<string, unknown> | null = null;
    if (action === "addNode") {
      const mediaDoc = await tx.get(panoramaMediaPath!);
      panoramaMedia = documentData(mediaDoc);
      const alreadyLinked = nodes.find((node) => node.original_path === newNodePath);
      if (alreadyLinked && panoramaMedia?.uid === principal.uid && panoramaMedia.mediaType === "panorama" && panoramaMedia.status === "awaiting-privacy-processing" && panoramaMedia.originalPath === newNodePath && Number(panoramaMedia.linkedTourId) === Number(data.tourId)) return Response.json(tourPayload({ ...tour, nodes }));
      if (!panoramaMedia || panoramaMedia.uid !== principal.uid || panoramaMedia.mediaType !== "panorama" || panoramaMedia.status !== "awaiting-privacy-processing" || panoramaMedia.originalPath !== newNodePath || panoramaMedia.linkedTourId != null) throw new ApiError(412, "The panorama is not available for this tour.");
      if (nodes.length >= 40) throw new ApiError(412, "A tour can contain at most 40 viewpoints.");
      const nodeId = nodes.reduce((max, node) => Math.max(max, Number(node.id) || 0), 0) + 1;
      const previous = nodes.length ? nodes[nodes.length - 1] : null;
      const node = { id: nodeId, title: newNodeTitle!, image: "", original_path: newNodePath!, connections: previous ? [Number(previous.id)] : [], privacy_status: "processing", owner_reviewed: false, manual_blur: false, original_retained: true, blur_regions: [] };
      if (previous) {
        const previousIndex = nodes.length - 1;
        nodes[previousIndex] = { ...previous, connections: [...new Set([...(Array.isArray(previous.connections) ? previous.connections as number[] : []), nodeId])] };
      }
      nodes.push(node);
      tx.patch(panoramaMediaPath!, { linkedTourId: Number(data.tourId), linkedAt: new Date(), updatedAt: new Date() });
      tx.patch(tourPath, { nodes, updatedAt: new Date() });
      return Response.json(tourPayload({ ...tour, nodes }));
    }
    if (action === "connect") {
      const from = data.fromNodeId, to = data.toNodeId;
      if (!Number.isSafeInteger(from) || !Number.isSafeInteger(to) || from === to) throw new ApiError(400, "Choose two different viewpoints.");
      const left = nodes.find((node) => node.id === from), right = nodes.find((node) => node.id === to);
      if (!left || !right) throw new ApiError(404, "A selected viewpoint was not found.");
      left.connections = [...new Set([...(Array.isArray(left.connections) ? left.connections as number[] : []), Number(to)])];
      right.connections = [...new Set([...(Array.isArray(right.connections) ? right.connections as number[] : []), Number(from)])];
    } else {
      throw new ApiError(400, "This tour action is not available.");
    }
    tx.patch(tourPath, { nodes, updatedAt: new Date() });
    return Response.json(tourPayload({ ...tour, nodes }));
  });
}
