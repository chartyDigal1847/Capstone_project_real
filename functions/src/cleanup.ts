import { Timestamp } from "firebase-admin/firestore";
import { getStorage } from "firebase-admin/storage";
import { onSchedule } from "firebase-functions/v2/scheduler";
import * as logger from "firebase-functions/logger";
import { db } from "./admin";

const RETENTION_MS = 30 * 24 * 60 * 60 * 1000;
const PAGE_SIZE = 100;
const CLEANABLE_STATUSES = ["failed", "ready", "expired"];

function unlinked(data: FirebaseFirestore.DocumentData): boolean {
  return data.linkedProductId == null && data.linkedStoreId == null;
}

function deletablePaths(data: FirebaseFirestore.DocumentData, uid: string): string[] {
  const candidates = [data.quarantinePath, data.publicPath, data.privatePath, data.originalPath];
  const prefixes = [
    `products/quarantine/${uid}/`,
    `products/public/${uid}/`,
    `stores/quarantine/${uid}/`,
    `stores/processed/${uid}/`,
    `tours/originals/${uid}/`,
  ];
  return [...new Set(candidates.filter((path): path is string =>
    typeof path === "string" && prefixes.some((prefix) => path.startsWith(prefix)),
  ))];
}

export const cleanupExpiredMediaAssets = onSchedule(
  { schedule: "every day 03:00", timeZone: "Asia/Manila", region: "asia-southeast1", maxInstances: 1 },
  async () => {
    const cutoff = Timestamp.fromMillis(Date.now() - RETENTION_MS);
    const bucket = getStorage().bucket();
    let removed = 0;

    for (const status of CLEANABLE_STATUSES) {
      let cursor: FirebaseFirestore.QueryDocumentSnapshot | undefined;
      while (true) {
        let query = db.collection("mediaAssets")
          .where("status", "==", status)
          .where("updatedAt", "<=", cutoff)
          .orderBy("updatedAt", "asc")
          .limit(PAGE_SIZE);
        if (cursor) query = query.startAfter(cursor);
        const page = await query.get();
        if (page.empty) break;

        for (const candidate of page.docs) {
          const claimed = await db.runTransaction(async (transaction) => {
            const current = await transaction.get(candidate.ref);
            const data = current.data();
            if (!current.exists || data?.status !== status || !unlinked(data) ||
                !(data.updatedAt instanceof Timestamp) || data.updatedAt.toMillis() > cutoff.toMillis()) {
              return null;
            }
            if (status === "ready" && data.mediaType !== "product" && data.mediaType !== "store") return null;
            transaction.update(candidate.ref, {
              status: "expired",
              cleanupClaimedAt: Timestamp.now(),
            });
            return { uid: String(data.uid ?? ""), paths: deletablePaths(data, String(data.uid ?? "")) };
          });
          if (!claimed) continue;

          try {
            await Promise.all(claimed.paths.map((path) => bucket.file(path).delete({ ignoreNotFound: true })));
            await candidate.ref.delete();
            removed++;
          } catch (error) {
            logger.error("Expired media cleanup failed; the claimed record will be retried", {
              errorType: error instanceof Error ? error.name : "unknown",
            });
          }
        }
        cursor = page.docs[page.docs.length - 1];
        if (page.size < PAGE_SIZE) break;
      }
    }

    logger.info("Expired unlinked media cleanup completed", { removed });
  },
);
