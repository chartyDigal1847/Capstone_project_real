import { Timestamp } from "firebase-admin/firestore";
import { onSchedule } from "firebase-functions/v2/scheduler";
import * as logger from "firebase-functions/logger";
import { db } from "./admin";
import { deleteStoredObject } from "./media_quota";
import { R2_GATEWAY_PRIVATE_JWK } from "./r2_gateway";

const RETENTION_MS = 30 * 24 * 60 * 60 * 1000;
const PAGE_SIZE = 100;
const CLEANABLE_STATUSES = ["failed", "ready", "expired", "cleanup-pending"];

function unlinked(data: FirebaseFirestore.DocumentData): boolean {
  return data.linkedProductId == null && data.linkedStoreId == null && data.linkedTourId == null;
}

export const cleanupExpiredMediaAssets = onSchedule(
  { schedule: "every day 03:00", timeZone: "Asia/Manila", region: "asia-southeast1", maxInstances: 1, secrets: [R2_GATEWAY_PRIVATE_JWK] },
  async () => {
    const cutoff = Timestamp.fromMillis(Date.now() - RETENTION_MS);
    let removed = 0;

    for (const status of CLEANABLE_STATUSES) {
      let cursor: FirebaseFirestore.QueryDocumentSnapshot | undefined;
      while (true) {
        let query = db.collection("mediaAssets").where("status", "==", status).limit(PAGE_SIZE);
        if (status !== "cleanup-pending") query = query.where("updatedAt", "<=", cutoff).orderBy("updatedAt", "asc");
        else query = query.orderBy("updatedAt", "asc");
        if (cursor) query = query.startAfter(cursor);
        const page = await query.get();
        if (page.empty) break;

        for (const candidate of page.docs) {
          const claim = await db.runTransaction(async (transaction) => {
            const current = await transaction.get(candidate.ref);
            const data = current.data();
            if (!current.exists || data?.status !== status || !unlinked(data) ||
                !(data.updatedAt instanceof Timestamp) || data.updatedAt.toMillis() > cutoff.toMillis()) return null;
            if (status === "ready" && data.mediaType !== "product" && data.mediaType !== "store") return null;
            if (status === "cleanup-pending" && data.cleanupClaimedAt instanceof Timestamp &&
                data.cleanupClaimedAt.toMillis() > Date.now() - 15 * 60 * 1000) return null;
            transaction.update(candidate.ref, { status: "cleanup-pending", cleanupClaimedAt: Timestamp.now() });
            const objectKeys = new Set([data.objectKey, data.quarantinePath, data.publicPath, data.privatePath, data.originalPath, data.pendingOutputPath, data.pendingPublicPath]
              .filter((key): key is string => typeof key === "string"));
            return { objectKeys: [...objectKeys] };
          });
          if (!claim) continue;

          try {
            for (const key of claim.objectKeys) await deleteStoredObject(key, "system:cleanup", "expired-unlinked-media");
            await candidate.ref.set({
              status: "deleted",
              accountingState: "deleted",
              deletedAt: Timestamp.now(),
              cleanupClaimedAt: null,
              updatedAt: Timestamp.now(),
            }, { merge: true });
            removed++;
          } catch (error) {
            await candidate.ref.set({
              status,
              cleanupClaimedAt: null,
              cleanupErrorAt: Timestamp.now(),
            }, { merge: true });
            logger.error("Expired R2 media cleanup failed; the object remains accounted and will be retried", {
              errorType: error instanceof Error ? error.name : "unknown",
            });
          }
        }
        cursor = page.docs[page.docs.length - 1];
        if (page.size < PAGE_SIZE) break;
      }
    }

    logger.info("Expired unlinked R2 media cleanup completed", { removed });
  },
);
