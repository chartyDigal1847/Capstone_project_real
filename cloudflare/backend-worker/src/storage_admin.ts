import { documentData, FirestoreRest } from "./firestore.js";
import type { Env, Principal } from "./index.js";
import { ApiError } from "./errors.js";

const LIMIT_BYTES = 9_000_000_000;

function state(used: number, reserved: number): "normal" | "warning" | "critical" | "full" {
  const ratio = (used + reserved) / LIMIT_BYTES;
  return ratio >= 1 ? "full" : ratio >= 0.9 ? "critical" : ratio >= 0.8 ? "warning" : "normal";
}

function serialize(value: unknown): unknown {
  if (value instanceof Date) return value.toISOString();
  if (Array.isArray(value)) return value.map(serialize);
  if (value && typeof value === "object") return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, serialize(item)]));
  return value;
}

export async function handleStorageAdmin(request: Request, env: Env, principal: Principal, path: string): Promise<Response> {
  if (request.method !== "POST") return Response.json({ error: "Method not allowed." }, { status: 405, headers: { Allow: "POST" } });
  const db = new FirestoreRest(env);
  const profile = documentData(await db.get(`users/${principal.uid}`));
  if (profile?.role !== "admin") throw new ApiError(403, "Administrator access is required.");
  if (path === "/api/v1/admin/storage/quota") {
    const [quotaDoc, storedImages, awaitingPanoramas, countedPanoramas, pendingUploads, failedUploads, activityDocs, reports] = await Promise.all([
      db.get("system_config/storage_quota"),
      db.count("mediaAssets", [
        { field: "status", op: "EQUAL", value: "ready" },
        { field: "mediaType", op: "IN", value: ["product", "store"] },
      ]),
      db.count("mediaAssets", [{ field: "status", op: "EQUAL", value: "awaiting-privacy-processing" }]),
      db.count("mediaAssets", [
        { field: "mediaType", op: "EQUAL", value: "panorama" },
        { field: "accountingState", op: "EQUAL", value: "counted" },
      ]),
      db.count("uploadReservations", [{ field: "status", op: "EQUAL", value: "reserved" }]),
      db.count("mediaAssets", [{ field: "status", op: "EQUAL", value: "failed" }]),
      db.query("storageAudit", [], 20, undefined, [{ field: "createdAt", direction: "DESCENDING" }]),
      db.query("storageReconciliations", [], 1, undefined, [{ field: "startedAt", direction: "DESCENDING" }]),
    ]);
    const quota = documentData(quotaDoc) ?? {};
    const usedBytes = Number(quota.usedBytes ?? 0);
    const reservedBytes = Number(quota.reservedBytes ?? 0);
    const latest = reports[0] ? documentData(reports[0]) : null;
    return Response.json({
      storageProvider: "cloudflare_r2",
      limitBytes: Number(quota.limitBytes ?? LIMIT_BYTES),
      usedBytes,
      reservedBytes,
      remainingBytes: Number(quota.remainingBytes ?? 0),
      actualBytes: Number(quota.actualBytes ?? 0),
      usagePercent: Number(quota.usagePercent ?? 0),
      state: state(usedBytes, reservedBytes),
      uploadEnabled: quota.uploadEnabled === true && quota.maintenanceLock !== true,
      storedImages,
      storedPanoramas: Math.max(awaitingPanoramas, countedPanoramas),
      pendingUploads,
      failedUploads,
      orphanedObjects: Number(quota.orphanedObjectsCount ?? 0),
      missingObjects: Number(quota.missingObjectsCount ?? 0),
      lastReconciledAt: quota.lastReconciledAt instanceof Date ? quota.lastReconciledAt.toISOString() : null,
      latestReport: latest ? serialize(latest) : null,
      recentActivity: activityDocs.map((doc) => ({ id: doc.name.split("/").at(-1), ...(serialize(documentData(doc) ?? {}) as Record<string, unknown>) })),
    }, { headers: { "Cache-Control": "no-store" } });
  }
  return Response.json({ error: "This storage administration action requires the R2 reconciliation port." }, { status: 501, headers: { "Cache-Control": "no-store" } });
}
