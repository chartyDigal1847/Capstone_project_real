import { describe, expect, it } from "vitest";
import { ApiError } from "../src/errors.js";
import { claimMediaDeletion } from "../src/media_delete.js";
import type { FirestoreRest, FirestoreTransaction } from "../src/firestore.js";

describe("media deletion claim", () => {
  it("rejects a media item that became linked before the transactional claim", async () => {
    const patches: unknown[][] = [];
    const latestMedia = {
      name: "projects/demo-localspot/databases/(default)/documents/mediaAssets/owner-asset",
      fields: {
        uid: { stringValue: "owner" },
        status: { stringValue: "ready" },
        linkedProductId: { integerValue: "42" },
      },
    };
    const fakeDb = {
      runTransaction: async <T>(callback: (tx: FirestoreTransaction) => Promise<T>) => callback({
        get: async (path: string) => path === "mediaAssets/owner-asset" ? latestMedia : null,
        patch: (...args: unknown[]) => { patches.push(args); },
      } as unknown as FirestoreTransaction),
    } as unknown as FirestoreRest;

    await expect(claimMediaDeletion(fakeDb, "mediaAssets/owner-asset", "owner"))
      .rejects.toMatchObject({ status: 412 } satisfies Partial<ApiError>);
    expect(patches).toHaveLength(0);
  });
});
