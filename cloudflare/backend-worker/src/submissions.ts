import { documentData, FirestoreRest } from "./firestore.js";
import type { Env, Principal } from "./index.js";
import { ApiError } from "./errors.js";

type Body = Record<string, unknown>;

async function jsonBody(request: Request): Promise<Body> {
  const declared = Number(request.headers.get("Content-Length") ?? "0");
  if (declared > 16 * 1024) throw new ApiError(413, "The request body is too large.");
  let value: unknown;
  try { value = await request.json(); } catch { throw new ApiError(400, "A valid JSON object is required."); }
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new ApiError(400, "A JSON object is required.");
  return value as Body;
}

function requiredText(value: unknown, label: string, max: number): string {
  if (typeof value !== "string") throw new ApiError(400, `${label} must be text.`);
  const normalized = value.trim();
  if (!normalized || normalized.length > max) throw new ApiError(400, `${label} must be between 1 and ${max} characters.`);
  return normalized;
}

async function profile(db: FirestoreRest, uid: string): Promise<Record<string, unknown>> {
  const found = documentData(await db.get(`users/${uid}`));
  if (!found || !Number.isSafeInteger(found.numericId) || Number(found.numericId) <= 0) {
    throw new ApiError(412, "Your account profile is not ready yet.");
  }
  return found;
}

async function allocateId(tx: import("./firestore.js").FirestoreTransaction, collection: string, counterName: string): Promise<number> {
  const path = `systemCounters/${counterName}`;
  const counter = documentData(await tx.get(path));
  let id: number;
  if (counter) {
    id = Number(counter.value ?? 0) + 1;
  } else {
    const highest = await tx.query(collection, [], 1, [{ field: "numericId", direction: "DESCENDING" }]);
    id = Number(documentData(highest[0] ?? null)?.numericId ?? 0) + 1;
  }
  if (!Number.isSafeInteger(id) || id <= 0) throw new ApiError(503, "A new record ID could not be allocated.");
  tx.set(path, { value: id });
  return id;
}

async function rateLimit(tx: import("./firestore.js").FirestoreTransaction, uid: string, operation: string, maximum: number, windowMs: number): Promise<void> {
  const path = `systemRateLimits/${uid}_${operation}`;
  const current = documentData(await tx.get(path));
  const now = new Date();
  const startedAt = current?.windowStartedAt instanceof Date ? current.windowStartedAt : null;
  const elapsed = startedAt ? now.getTime() - startedAt.getTime() : null;
  const withinWindow = elapsed !== null && elapsed >= 0 && elapsed < windowMs;
  const count = withinWindow ? Number(current?.count ?? 0) : 0;
  if (count >= maximum) throw new ApiError(429, "You have reached the request limit. Try again later.");
  tx.set(path, {
    uid,
    operation,
    windowStartedAt: withinWindow ? startedAt! : now,
    count: count + 1,
    updatedAt: now,
  });
}

async function submit(request: Request, env: Env, principal: Principal, isReport: boolean): Promise<Response> {
  if (request.method !== "POST") return Response.json({ error: "Method not allowed." }, { status: 405, headers: { Allow: "POST" } });
  const data = await jsonBody(request);
  const user = await profile(new FirestoreRest(env), principal.uid);
  const db = new FirestoreRest(env);
  const nowWindow = 24 * 60 * 60 * 1000;
  if (isReport) {
    const target = requiredText(data.target, "Report target", 120);
    const reason = requiredText(data.reason, "Report reason", 400);
    const id = await db.runTransaction(async (tx) => {
      await rateLimit(tx, principal.uid, "userReport", 10, nowWindow);
      const numericId = await allocateId(tx, "reports", "reportIds");
      tx.create(`reports/${crypto.randomUUID()}`, { numericId, userId: user.numericId, uid: principal.uid, target, reason, resolved: false });
      return numericId;
    });
    return Response.json({ ok: true, id });
  }
  const topic = requiredText(data.topic, "Topic", 80);
  const body = requiredText(data.body, "Feedback", 1000);
  const area = data.area == null ? "" : typeof data.area === "string" ? data.area.trim() : null;
  if (area == null || area.length > 120) throw new ApiError(400, "Area must be 120 characters or fewer.");
  const id = await db.runTransaction(async (tx) => {
    await rateLimit(tx, principal.uid, "userFeedback", 5, nowWindow);
    const numericId = await allocateId(tx, "feedback", "feedbackIds");
    tx.create(`feedback/${crypto.randomUUID()}`, { numericId, userId: user.numericId, uid: principal.uid, topic, body, ...(area ? { area } : {}) });
    return numericId;
  });
  return Response.json({ ok: true, id });
}

export async function handleSubmissions(request: Request, env: Env, principal: Principal, path: string): Promise<Response> {
  if (path === "/api/v1/feedback") return submit(request, env, principal, false);
  if (path === "/api/v1/reports") return submit(request, env, principal, true);
  if (path !== "/api/v1/admin/reports/resolve") throw new ApiError(404, "Route not found.");
  if (request.method !== "POST") return Response.json({ error: "Method not allowed." }, { status: 405, headers: { Allow: "POST" } });
  const data = await jsonBody(request);
  const reportId = data.reportId;
  if (typeof reportId !== "number" || !Number.isSafeInteger(reportId) || reportId <= 0) throw new ApiError(400, "A valid report ID is required.");
  const db = new FirestoreRest(env);
  const admin = documentData(await db.get(`users/${principal.uid}`));
  if (admin?.role !== "admin") throw new ApiError(403, "Administrator access is required.");
  const matches = await db.query("reports", [{ field: "numericId", op: "EQUAL", value: reportId }], 1);
  const match = matches[0];
  if (!match) throw new ApiError(404, "Report was not found.");
  const documentPath = match.name.split("/documents/")[1];
  await db.runTransaction(async (tx) => {
    const report = documentData(await tx.get(documentPath));
    if (!report) throw new ApiError(404, "Report was not found.");
    if (report.resolved === true) return;
    const now = new Date().toISOString();
    tx.patch(documentPath, { resolved: true, resolvedByUid: principal.uid, resolvedAt: now });
    tx.create(`auditLogs/${crypto.randomUUID()}`, { action: "report.resolved", reportId, actorUid: principal.uid, created_at: now });
  });
  return Response.json({ ok: true, reportId });
}
