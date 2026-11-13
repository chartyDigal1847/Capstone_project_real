const assert = require("node:assert/strict");
const { randomUUID } = require("node:crypto");
const path = require("node:path");
const { createRequire } = require("node:module");

const projectId = process.env.GCLOUD_PROJECT || "demo-localspot";
process.env.FIRESTORE_EMULATOR_HOST ||= "127.0.0.1:8080";
process.env.FIREBASE_STORAGE_EMULATOR_HOST ||= "127.0.0.1:9199";
process.env.FIREBASE_CONFIG = JSON.stringify({
  projectId,
  storageBucket: `${projectId}.appspot.com`,
});
const requireFunctions = createRequire(path.resolve(__dirname, "../functions/package.json"));
const { initializeApp } = requireFunctions("firebase-admin/app");
const { getFirestore, Timestamp } = requireFunctions("firebase-admin/firestore");
const { getStorage } = requireFunctions("firebase-admin/storage");

const app = initializeApp({ projectId, storageBucket: `${projectId}.appspot.com` });
const db = getFirestore(app);
const bucket = getStorage(app).bucket();
const cleanupExpiredMediaAssets = require("../functions/lib").cleanupExpiredMediaAssets;

async function seedAsset({ id, status, updatedAt, mediaType = "product", linkedProductId = null, path: objectPath, pathField = "publicPath" }) {
  if (objectPath) {
    await bucket.file(objectPath).save(Buffer.from("smoke-media"), {
      resumable: false,
      metadata: { contentType: "image/png" },
    });
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

    assert.equal((await db.collection("mediaAssets").doc(staleId).get()).exists, false, "Old unlinked media record is removed");
    assert.equal((await bucket.file(stalePath).exists())[0], false, "Old unlinked media object is removed");
    assert.equal((await db.collection("mediaAssets").doc(linkedId).get()).exists, true, "Linked catalog media is preserved");
    assert.equal((await bucket.file(linkedPath).exists())[0], true, "Linked catalog image is preserved");
    assert.equal((await db.collection("mediaAssets").doc(freshId).get()).exists, true, "Recent upload is preserved");
    assert.equal((await bucket.file(freshPath).exists())[0], true, "Recent media object is preserved");
    assert.equal((await db.collection("mediaAssets").doc(failedId).get()).exists, false, "Old failed media record is removed");
    assert.equal((await bucket.file(failedQuarantinePath).exists())[0], false, "Failed quarantine object is removed");
    assert.equal((await db.collection("mediaAssets").doc(failedPanoramaId).get()).exists, false, "Old failed panorama record is removed");
    assert.equal((await bucket.file(failedPanoramaPath).exists())[0], false, "Failed private panorama original is removed");
    console.log("Media cleanup smoke checks passed (stale failed originals removed; linked and recent media preserved)");
  } finally {
    const batch = db.batch();
    for (const id of assets) batch.delete(db.collection("mediaAssets").doc(id));
    await batch.commit();
    await Promise.all(paths.map((objectPath) => bucket.file(objectPath).delete({ ignoreNotFound: true })));
    await db.terminate();
    await app.delete();
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
