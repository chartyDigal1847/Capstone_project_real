import { documentData, FirestoreRest } from "./firestore.js";
import type { Env, Principal } from "./index.js";
import { ApiError } from "./errors.js";

async function jsonBody(request: Request): Promise<Record<string, unknown>> {
  try {
    const value: unknown = await request.json();
    if (value && typeof value === "object" && !Array.isArray(value)) return value as Record<string, unknown>;
  } catch { /* handled below */ }
  throw new ApiError(400, "A valid JSON object is required.");
}

function text(value: unknown, field: string, max: number): string {
  if (typeof value !== "string") throw new ApiError(400, `${field} must be text.`);
  const result = value.trim();
  if (!result || result.length > max) throw new ApiError(400, `${field} is invalid.`);
  return result;
}

async function assertPromotionAccess(db: FirestoreRest, uid: string, storeId: number): Promise<void> {
  const storeDoc = (await db.query("stores", [{ field: "numericId", op: "EQUAL", value: storeId }], 1))[0];
  const store = documentData(storeDoc ?? null);
  if (!store) throw new ApiError(404, "Store was not found.");
  if (store.status !== "approved") throw new ApiError(412, "The store is not approved.");
  if (store.ownerUid === uid) return;
  const membership = documentData((await db.query("storeMembers", [
    { field: "storeId", op: "EQUAL", value: storeId },
    { field: "userUid", op: "EQUAL", value: uid },
  ], 1))[0] ?? null);
  if (membership?.promotions !== true) throw new ApiError(403, "promotions access to this store is required.");
}

async function createPromotion(request: Request, env: Env, principal: Principal): Promise<Response> {
  if (request.method !== "POST") return Response.json({ error: "Method not allowed." }, { status: 405, headers: { Allow: "POST" } });
  const data = await jsonBody(request);
  const storeId = data.storeId;
  if (typeof storeId !== "number" || !Number.isSafeInteger(storeId) || storeId <= 0) throw new ApiError(400, "A valid store ID is required.");
  const db = new FirestoreRest(env);
  await assertPromotionAccess(db, principal.uid, storeId);
  const startsAt = text(data.starts_at, "starts_at", 64);
  const endsAt = text(data.ends_at, "ends_at", 64);
  const startMs = Date.parse(startsAt);
  const endMs = Date.parse(endsAt);
  if (!Number.isFinite(startMs) || !Number.isFinite(endMs) || startMs >= endMs) throw new ApiError(400, "Promotion dates are invalid.");
  const title = text(data.title, "title", 80);
  const offer = text(data.offer, "offer", 200);
  const numericId = await db.runTransaction(async (tx) => {
    const limitPath = `systemRateLimits/${principal.uid}_storePromotion`;
    const current = documentData(await tx.get(limitPath));
    const now = new Date();
    const startedAt = current?.windowStartedAt instanceof Date ? current.windowStartedAt : null;
    const elapsed = startedAt ? now.getTime() - startedAt.getTime() : null;
    const activeWindow = elapsed !== null && elapsed >= 0 && elapsed < 24 * 60 * 60 * 1000;
    const count = activeWindow ? Number(current?.count ?? 0) : 0;
    if (count >= 10) throw new ApiError(429, "You have reached the promotion request limit. Try again later.");
    tx.set(limitPath, { uid: principal.uid, operation: "storePromotion", windowStartedAt: activeWindow ? startedAt! : now, count: count + 1, updatedAt: now });
    const counterPath = "systemCounters/promotionIds";
    const counter = documentData(await tx.get(counterPath));
    let nextId: number;
    if (counter) nextId = Number(counter.value ?? 0) + 1;
    else {
      const last = await tx.query("promotions", [], 1, [{ field: "numericId", direction: "DESCENDING" }]);
      nextId = Number(documentData(last[0] ?? null)?.numericId ?? 0) + 1;
    }
    if (!Number.isSafeInteger(nextId) || nextId <= 0) throw new ApiError(503, "A promotion ID could not be allocated.");
    tx.set(counterPath, { value: nextId });
    tx.create(`promotions/${crypto.randomUUID()}`, {
      numericId: nextId,
      storeId,
      title,
      offer,
      starts_at: new Date(startMs).toISOString(),
      ends_at: new Date(endMs).toISOString(),
      sponsored: false,
      sponsoredRequested: data.sponsored === true,
      status: "pending",
      ownerUid: principal.uid,
    });
    return nextId;
  });
  return Response.json({ id: numericId, status: "pending" });
}

async function reviewPromotion(request: Request, env: Env, principal: Principal): Promise<Response> {
  if (request.method !== "POST") return Response.json({ error: "Method not allowed." }, { status: 405, headers: { Allow: "POST" } });
  const data = await jsonBody(request);
  const promotionId = data.promotionId;
  const status = data.status;
  if (typeof promotionId !== "number" || !Number.isSafeInteger(promotionId) || promotionId <= 0) throw new ApiError(400, "A valid promotion ID is required.");
  if (status !== "approved" && status !== "rejected") throw new ApiError(400, "Promotion status is not supported.");
  const db = new FirestoreRest(env);
  const admin = documentData(await db.get(`users/${principal.uid}`));
  if (admin?.role !== "admin") throw new ApiError(403, "Administrator access is required.");
  const matches = await db.query("promotions", [{ field: "numericId", op: "EQUAL", value: promotionId }], 1);
  if (!matches[0]) throw new ApiError(404, "Promotion was not found.");
  const path = matches[0].name.split("/documents/")[1];
  await db.runTransaction(async (tx) => {
    const promotion = documentData(await tx.get(path));
    if (!promotion) throw new ApiError(404, "Promotion was not found.");
    if (promotion.status === status) return;
    if (promotion.status !== "pending") throw new ApiError(412, "Only pending promotions can be reviewed.");
    tx.patch(path, { status, sponsored: status === "approved" && promotion.sponsoredRequested === true });
    tx.create(`auditLogs/${crypto.randomUUID()}`, {
      action: `promotion.status.${status}`,
      promotionId,
      storeId: promotion.storeId,
      actorUid: principal.uid,
      created_at: new Date().toISOString(),
    });
  });
  return Response.json({ id: promotionId, status });
}

export async function handlePromotions(request: Request, env: Env, principal: Principal, path: string): Promise<Response> {
  if (path === "/api/v1/promotions") return createPromotion(request, env, principal);
  if (path === "/api/v1/admin/promotions/review") return reviewPromotion(request, env, principal);
  throw new ApiError(404, "Route not found.");
}
