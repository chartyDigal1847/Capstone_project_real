import { afterEach, describe, expect, it, vi } from "vitest";
import { FirestoreRest, type FirestoreDocument, type FirestoreTransaction } from "../src/firestore.js";
import { runExpiredMediaCleanup } from "../src/media_expiry_cleanup.js";
import { deleteStoredObject } from "../src/storage_orphans.js";

vi.mock("../src/storage_orphans.js", () => ({ deleteStoredObject: vi.fn() }));

const env = {
  MEDIA_BUCKET: {} as R2Bucket,
  FIREBASE_PROJECT_ID: "demo-localspot",
  FIREBASE_PROJECT_NUMBER: "1",
  FIRESTORE_EMULATOR_URL: "http://127.0.0.1:8080",
  LOCAL_EMULATORS: "true",
};

function mediaDoc(id: string, fields: Record<string, unknown>): FirestoreDocument {
  return {
    name: `projects/demo-localspot/databases/(default)/documents/mediaAssets/${id}`,
    fields: Object.fromEntries(Object.entries(fields).map(([key, value]) => [key, value instanceof Date ? { timestampValue: value.toISOString() } : typeof value === "string" ? { stringValue: value } : { booleanValue: value }])),
  };
}

afterEach(() => vi.restoreAllMocks());

describe("resumable expired media cleanup", () => {
  it("scans at most five candidates and saves the cursor for the next run", async () => {
    const candidates = Array.from({ length: 8 }, (_, index) => mediaDoc(`linked-${index}`, {
      status: "failed",
      linkedProductId: "still-linked",
      updatedAt: new Date(Date.now() - 31 * 24 * 60 * 60 * 1000),
    }));
    vi.spyOn(FirestoreRest.prototype, "get").mockResolvedValue(null);
    vi.spyOn(FirestoreRest.prototype, "query").mockImplementation(async (_collection, _filters, limit) => candidates.slice(0, limit));
    const runTransaction = vi.spyOn(FirestoreRest.prototype, "runTransaction").mockImplementation(async (callback) => callback({
      get: async () => candidates[0],
      patch: () => undefined,
    } as unknown as FirestoreTransaction));
    const saveCheckpoint = vi.spyOn(FirestoreRest.prototype, "set").mockResolvedValue(undefined);

    expect(await runExpiredMediaCleanup(env)).toBe(0);
    expect(runTransaction).toHaveBeenCalledTimes(5);
    expect(saveCheckpoint).toHaveBeenCalledWith("system_config/expired_media_cleanup", expect.objectContaining({
      statusIndex: 0,
      cursor: candidates[4].name,
    }));
  });

  it("deletes at most two R2 objects and retains the rest on the claimed record", async () => {
    const candidate = mediaDoc("expired-with-many-objects", {
      status: "failed",
      mediaType: "product",
      updatedAt: new Date(Date.now() - 31 * 24 * 60 * 60 * 1000),
      objectKey: "products/private/a.jpg",
      publicPath: "products/public/a.jpg",
      quarantinePath: "products/quarantine/a.jpg",
    });
    vi.spyOn(FirestoreRest.prototype, "get").mockResolvedValue(null);
    vi.spyOn(FirestoreRest.prototype, "query").mockResolvedValue([candidate]);
    const patches: Array<Record<string, unknown>> = [];
    vi.spyOn(FirestoreRest.prototype, "runTransaction").mockImplementation(async (callback) => callback({
      get: async () => candidate,
      patch: (_path: string, fields: Record<string, unknown>) => { patches.push(fields); },
    } as unknown as FirestoreTransaction));
    vi.spyOn(FirestoreRest.prototype, "set").mockResolvedValue(undefined);
    vi.mocked(deleteStoredObject).mockResolvedValue(undefined);

    expect(await runExpiredMediaCleanup(env)).toBe(0);
    expect(deleteStoredObject).toHaveBeenCalledTimes(2);
    expect(patches.some((fields) => fields.status === "cleanup-pending" &&
      Array.isArray(fields.cleanupRemainingKeys) && fields.cleanupRemainingKeys.length === 1 &&
      fields.cleanupClaimedAt === null)).toBe(true);
  });
});
