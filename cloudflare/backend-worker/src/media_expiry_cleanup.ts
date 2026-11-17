import { documentData, FirestoreRest } from "./firestore.js";
import type { Env } from "./index.js";
import { deleteStoredObject } from "./storage_orphans.js";

const RETENTION_MS = 30 * 24 * 60 * 60 * 1000;
const PAGE_SIZE = 5;
const MAX_OBJECTS_PER_RUN = 2;
const CLEANABLE_STATUSES = ["failed", "ready", "expired", "cleanup-pending"];
const CHECKPOINT_PATH = "system_config/expired_media_cleanup";

function unlinked(data: Record<string, unknown>): boolean {
  return data.linkedProductId == null && data.linkedStoreId == null && data.linkedTourId == null;
}

function objectKeys(data: Record<string, unknown>): string[] {
  return [...new Set([data.objectKey, data.quarantinePath, data.publicPath, data.privatePath, data.originalPath, data.pendingOutputPath, data.pendingPublicPath]
    .filter((key): key is string => typeof key === "string"))];
}

export async function runExpiredMediaCleanup(env: Env): Promise<number> {
  const db = new FirestoreRest(env), cutoff = new Date(Date.now() - RETENTION_MS);
  const checkpoint = documentData(await db.get(CHECKPOINT_PATH));
  const checkpointIndex = checkpoint?.statusIndex;
  let statusIndex = Number.isSafeInteger(checkpointIndex) && Number(checkpointIndex) >= 0 && Number(checkpointIndex) < CLEANABLE_STATUSES.length
    ? Number(checkpointIndex) : 0;
  let cursor = typeof checkpoint?.cursor === "string" ? checkpoint.cursor : undefined;
  const status = CLEANABLE_STATUSES[statusIndex];
  const page = await db.query("mediaAssets", [{ field: "status", op: "EQUAL", value: status }], PAGE_SIZE, undefined, [{ field: "__name__", direction: "ASCENDING" }], cursor);
  let removed = 0, processed = 0, lastCursor = cursor;
  let stoppedAfterCleanup = false;

  for (const candidate of page) {
    processed++;
    lastCursor = candidate.name;
    const path = candidate.name.split("/documents/")[1];
    if (!path) continue;
    const claimed = await db.runTransaction(async (tx) => {
      const currentDoc = await tx.get(path), data = documentData(currentDoc);
      if (!currentDoc || !data || data.status !== status || !unlinked(data)) return null;
      if (status !== "cleanup-pending" && (!(data.updatedAt instanceof Date) || data.updatedAt.getTime() > cutoff.getTime())) return null;
      if (status === "ready" && data.mediaType !== "product" && data.mediaType !== "store") return null;
      if (status === "cleanup-pending" && data.cleanupClaimedAt instanceof Date && data.cleanupClaimedAt.getTime() > Date.now() - 15 * 60 * 1000) return null;
      const remaining = Array.isArray(data.cleanupRemainingKeys)
        ? data.cleanupRemainingKeys.filter((key): key is string => typeof key === "string")
        : objectKeys(data);
      tx.patch(path, { status: "cleanup-pending", cleanupClaimedAt: new Date(), cleanupRemainingKeys: remaining });
      return remaining;
    });
    if (!claimed) continue;

    try {
      const batch = claimed.slice(0, MAX_OBJECTS_PER_RUN);
      for (const key of batch) await deleteStoredObject(db, env, key, "system:cleanup", "expired-unlinked-media");
      const remaining = claimed.slice(batch.length);
      await db.runTransaction(async (tx) => {
        const currentDoc = await tx.get(path);
        if (!currentDoc) return;
        const now = new Date();
        if (remaining.length) {
          tx.patch(path, { status: "cleanup-pending", cleanupRemainingKeys: remaining, cleanupClaimedAt: null, updatedAt: now });
        } else {
          tx.patch(path, { status: "deleted", accountingState: "deleted", cleanupRemainingKeys: [], deletedAt: now, cleanupClaimedAt: null, updatedAt: now });
        }
      });
      if (!remaining.length) removed++;
      stoppedAfterCleanup = true;
      break;
    } catch (error) {
      await db.runTransaction(async (tx) => {
        const currentDoc = await tx.get(path);
        if (currentDoc) tx.patch(path, { status, cleanupClaimedAt: null, cleanupErrorAt: new Date() });
      });
      console.error("Expired R2 media cleanup failed; object remains accounted", { errorType: error instanceof Error ? error.name : "unknown" });
      stoppedAfterCleanup = true;
      break;
    }
  }

  if (!stoppedAfterCleanup && page.length < PAGE_SIZE) {
    statusIndex = (statusIndex + 1) % CLEANABLE_STATUSES.length;
    cursor = undefined;
  } else {
    cursor = lastCursor;
  }
  await db.set(CHECKPOINT_PATH, { statusIndex, cursor: cursor ?? null, updatedAt: new Date() });
  console.log("Expired unlinked R2 media cleanup batch completed", { removed, scanned: processed, status });
  return removed;
}
