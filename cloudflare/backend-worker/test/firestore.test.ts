import { describe, expect, it } from "vitest";
import type { Env } from "../src/index.js";
import { documentData, FirestoreRest } from "../src/firestore.js";

const emulatorUrl = process.env.FIRESTORE_EMULATOR_URL;
const integration = describe.skipIf(!emulatorUrl);

integration("Firestore REST emulator adapter", () => {
  it("reads and commits a document in one transaction", async () => {
    const env: Env = {
      MEDIA_BUCKET: {} as R2Bucket,
      FIREBASE_PROJECT_ID: "demo-localspot",
      FIREBASE_PROJECT_NUMBER: "1",
      FIRESTORE_EMULATOR_URL: emulatorUrl,
      LOCAL_EMULATORS: "true",
    };
    const db = new FirestoreRest(env);
    const id = `worker-tx-${crypto.randomUUID()}`;
    const path = `backendWorkerTests/${id}`;
    const name = `projects/demo-localspot/databases/(default)/documents/${path}`;
    const transaction = await db.beginTransaction();
    expect(await db.get(path, transaction)).toBeNull();
    await db.commit([{
      update: { name, fields: { status: { stringValue: "committed" } } },
      currentDocument: { exists: false },
    }], transaction);
    const saved = await db.get(path);
    expect(documentData(saved)).toEqual({ status: "committed" });
    await db.commit([{ delete: name }]);
  });

  it("walks Firestore document-name cursors across inventory pages", async () => {
    const env: Env = {
      MEDIA_BUCKET: {} as R2Bucket,
      FIREBASE_PROJECT_ID: "demo-localspot",
      FIREBASE_PROJECT_NUMBER: "1",
      FIRESTORE_EMULATOR_URL: emulatorUrl,
      LOCAL_EMULATORS: "true",
    };
    const db = new FirestoreRest(env);
    const id = `inventory-${crypto.randomUUID()}`;
    for (const suffix of ["a", "b", "c"]) await db.create("backendWorkerInventoryTests", { marker: id }, `${id}-${suffix}`);
    const found = await db.query("backendWorkerInventoryTests", [{ field: "marker", op: "EQUAL", value: id }], 10);
    const all = await db.listAll("backendWorkerInventoryTests", 2);
    expect(all.filter((doc) => doc.fields?.marker && found.some((item) => item.name === doc.name))).toHaveLength(3);
    await db.commit(found.map((doc) => ({ delete: doc.name })));
  });
});
