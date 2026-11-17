import { documentData, FirestoreRest } from "./firestore.js";
import type { Env, Principal } from "./index.js";
import { ApiError } from "./errors.js";
import { releaseExpired } from "./storage_reconciliation.js";

export async function cleanupAbandonedMediaReservations(request: Request, env: Env, principal: Principal): Promise<Response> {
  if (request.method !== "POST") return Response.json({ error: "Method not allowed." }, { status: 405, headers: { Allow: "POST" } });
  const db = new FirestoreRest(env), profile = documentData(await db.get(`users/${principal.uid}`));
  if (profile?.role !== "admin") throw new ApiError(403, "Administrator access is required.");
  const expired = await db.query("uploadReservations", [
    { field: "status", op: "EQUAL", value: "reserved" },
    { field: "expiresAt", op: "LESS_THAN_OR_EQUAL", value: new Date() },
  ], 100);
  let cleaned = 0;
  for (const reservation of expired) {
    const data = documentData(reservation);
    if (!data || !(data.expiresAt instanceof Date) || data.expiresAt.getTime() > Date.now()) continue;
    await releaseExpired(db, env, reservation);
    cleaned++;
  }
  return Response.json({ cleaned }, { headers: { "Cache-Control": "no-store" } });
}
