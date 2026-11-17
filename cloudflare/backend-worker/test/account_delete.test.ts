import { afterEach, describe, expect, it, vi } from "vitest";
import { accountMediaObjectKeys } from "../src/account_delete.js";
import { FirestoreRest } from "../src/firestore.js";

describe("account deletion media cleanup", () => {
  afterEach(() => vi.unstubAllGlobals());

  it("collects panorama revision objects owned by the deleting account only", () => {
    const keys = accountMediaObjectKeys("owner_1", {
      originalPath: "tours/originals/owner_1/7/original.jpg",
      latestDerivativeObjectKey: "tours/derivatives/owner_1/7/2/revision_a.jpg",
      publicPath: "products/public/someone_else/image.jpg",
    }, [
      { objectKey: "tours/derivatives/owner_1/7/2/revision_b.jpg" },
      { objectKey: "tours/derivatives/someone_else/7/2/foreign.jpg" },
    ]);

    expect(keys).toEqual([
      "tours/originals/owner_1/7/original.jpg",
      "tours/derivatives/owner_1/7/2/revision_a.jpg",
      "tours/derivatives/owner_1/7/2/revision_b.jpg",
    ]);
  });

  it("paginates revision subcollections with a stable document-name cursor", async () => {
    const firstName = "projects/demo-localspot/databases/(default)/documents/mediaAssets/u_a/derivatives/a";
    const secondName = "projects/demo-localspot/databases/(default)/documents/mediaAssets/u_a/derivatives/b";
    const pages = [
      [{ document: { name: firstName } }, { document: { name: secondName } }],
      [{ document: { name: "projects/demo-localspot/databases/(default)/documents/mediaAssets/u_a/derivatives/c" } }],
    ];
    const requests: Array<Record<string, unknown>> = [];
    vi.stubGlobal("fetch", vi.fn(async (_input: RequestInfo | URL, init?: RequestInit) => {
      requests.push(JSON.parse(String(init?.body)) as Record<string, unknown>);
      return Response.json(pages.shift());
    }));
    const db = new FirestoreRest({
      MEDIA_BUCKET: {} as R2Bucket,
      FIREBASE_PROJECT_ID: "demo-localspot",
      FIREBASE_PROJECT_NUMBER: "1",
      FIRESTORE_EMULATOR_URL: "http://firestore.test",
      LOCAL_EMULATORS: "true",
    });

    const documents = await db.listSubcollection("mediaAssets/u_a", "derivatives", 2);

    expect(documents.map((document) => document.name)).toHaveLength(3);
    const secondQuery = (requests[1].structuredQuery as Record<string, unknown>);
    expect(secondQuery.startAt).toEqual({ values: [{ referenceValue: secondName }], before: false });
  });
});
