const assert = require("node:assert/strict");
const { randomUUID } = require("node:crypto");
const path = require("node:path");
const { createRequire } = require("node:module");

const projectId = process.env.GCLOUD_PROJECT || "demo-localspot";
process.env.FIRESTORE_EMULATOR_HOST ||= "127.0.0.1:8080";
const requireFunctions = createRequire(path.resolve(__dirname, "../functions/package.json"));
const { initializeApp } = requireFunctions("firebase-admin/app");
const { getFirestore, Timestamp } = requireFunctions("firebase-admin/firestore");
const app = initializeApp({ projectId });
const db = getFirestore(app);
const r2Gateway = require("../functions/lib/r2_gateway.js");
const r2Objects = new Map();
r2Gateway.r2Head = async (key) => {
  const object = r2Objects.get(key);
  return object ? { key, size: object.length, contentType: "image/jpeg" } : null;
};
r2Gateway.r2Delete = async (key) => ({ existed: r2Objects.delete(key) });
const cleanupExpiredMediaAssets = require("../functions/lib").cleanupExpiredMediaAssets;

async function seedAsset({ id, status, updatedAt, mediaType = "product", linkedProductId = null, path: objectPath, pathField = "publicPath" }) {
  if (objectPath) {
    r2Objects.set(objectPath, Buffer.from("smoke-media"));
  }
  await db.collection("mediaAssets").doc(id).set({
    uid: "cleanup-smoke-user",
    assetId: id,
    mediaType,
    status,
    updatedAt: Timestamp.fromMillis(updatedAt),
    ...(linkedProductId == null ? {} : { linkedProductId }),
    ...(objectPath ? { [pathField]: objectPath } : {}),
  });
}

async function main() {
  const suffix = randomUUID();
  const oldMs = Date.now() - 31 * 24 * 60 * 60 * 1000;
  const currentMs = Date.now();
  const staleId = `cleanup_stale_${suffix}`;
  const linkedId = `cleanup_linked_${suffix}`;
  const freshId = `cleanup_fresh_${suffix}`;
  const failedId = `cleanup_failed_${suffix}`;
  const failedPanoramaId = `cleanup_failed_panorama_${suffix}`;
  const stalePath = `products/public/cleanup-smoke-user/${suffix}-stale.png`;
  const linkedPath = `products/public/cleanup-smoke-user/${suffix}-linked.png`;
  const freshPath = `products/public/cleanup-smoke-user/${suffix}-fresh.png`;
  const failedQuarantinePath = `products/quarantine/cleanup-smoke-user/${suffix}-invalid.png`;
  const failedPanoramaPath = `tours/originals/cleanup-smoke-user/123/${suffix}-invalid.jpg`;
  const assets = [staleId, linkedId, freshId, failedId, failedPanoramaId];
  const paths = [stalePath, linkedPath, freshPath, failedQuarantinePath, failedPanoramaPath];

  try {
    await seedAsset({ id: staleId, status: "ready", updatedAt: oldMs, path: stalePath });
    await seedAsset({ id: linkedId, status: "ready", updatedAt: oldMs, linkedProductId: 923456, path: linkedPath });
    await seedAsset({ id: freshId, status: "ready", updatedAt: currentMs, path: freshPath });
    await seedAsset({ id: failedId, status: "failed", updatedAt: oldMs, path: failedQuarantinePath, pathField: "quarantinePath" });
    await seedAsset({ id: failedPanoramaId, status: "failed", mediaType: "panorama", updatedAt: oldMs, path: failedPanoramaPath, pathField: "originalPath" });

    await cleanupExpiredMediaAssets.run({ scheduleTime: new Date().toISOString() });

    assert.equal((await db.collection("mediaAssets").doc(staleId).get()).data()?.status, "deleted", "Old unlinked media is marked deleted");
    assert.equal(r2Objects.has(stalePath), false, "Old unlinked media object is removed");
    assert.equal((await db.collection("mediaAssets").doc(linkedId).get()).exists, true, "Linked catalog media is preserved");
    assert.equal(r2Objects.has(linkedPath), true, "Linked catalog image is preserved");
    assert.equal((await db.collection("mediaAssets").doc(freshId).get()).exists, true, "Recent upload is preserved");
    assert.equal(r2Objects.has(freshPath), true, "Recent media object is preserved");
    assert.equal((await db.collection("mediaAssets").doc(failedId).get()).data()?.status, "deleted", "Old failed media is marked deleted");
    assert.equal(r2Objects.has(failedQuarantinePath), false, "Failed quarantine object is removed");
    assert.equal((await db.collection("mediaAssets").doc(failedPanoramaId).get()).data()?.status, "deleted", "Old failed panorama is marked deleted");
    assert.equal(r2Objects.has(failedPanoramaPath), false, "Failed private panorama original is removed");
    console.log("Media cleanup smoke checks passed (stale failed originals removed; linked and recent media preserved)");
  } finally {
    const batch = db.batch();
    for (const id of assets) batch.delete(db.collection("mediaAssets").doc(id));
    await batch.commit();
    for (const objectPath of paths) r2Objects.delete(objectPath);
    await db.terminate();
    await app.delete();
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
