const assert = require('node:assert/strict');

process.env.NODE_PATH = require('node:path').join(__dirname, '..', 'functions', 'node_modules');
require('node:module').Module._initPaths();

const { getApps, initializeApp, deleteApp } = require('firebase-admin/app');
const { getFirestore, Timestamp } = require('firebase-admin/firestore');
const gateway = require('../functions/lib/r2_gateway.js');
const quota = require('../functions/lib/media_quota.js');

async function main() {
  if (!process.env.FIRESTORE_EMULATOR_HOST) throw new Error('Run this script through Firebase emulators:exec.');
  process.env.GCLOUD_PROJECT ||= 'demo-localspot-r2';
  const app = getApps()[0] ?? initializeApp({ projectId: process.env.GCLOUD_PROJECT });
  const db = getFirestore(app);
  const quotaRef = db.collection('system_config').doc('storage_quota');
  await quotaRef.set({
    storageProvider: 'cloudflare_r2', limitBytes: quota.R2_STORAGE_LIMIT_BYTES,
    usedBytes: 0, reservedBytes: 0, remainingBytes: quota.R2_STORAGE_LIMIT_BYTES,
    uploadEnabled: true, maintenanceLock: false,
  });

  const reserve = (uid, id, size) => quota.reserveStorageBytes({
    uid, assetId: id, mediaType: 'product', objectKey: `products/quarantine/${uid}/${id}`,
    reservedBytes: size,
  }, Timestamp.fromMillis(Date.now() + 60_000));
  const contenders = await Promise.allSettled([
    reserve('uploader_a', 'asset_a', 5_000_000_000),
    reserve('uploader_b', 'asset_b', 5_000_000_000),
  ]);
  assert.equal(contenders.filter((item) => item.status === 'fulfilled').length, 1, 'only one concurrent reservation should fit');
  assert.equal(contenders.filter((item) => item.status === 'rejected').length, 1, 'the over-quota reservation should fail');
  let state = (await quotaRef.get()).data();
  assert.equal(state.reservedBytes, 5_000_000_000);
  assert.equal(state.usedBytes + state.reservedBytes <= state.limitBytes, true);

  const winningId = contenders.find((item) => item.status === 'fulfilled').value;
  await quota.releaseStorageReservation(winningId, 'test-release');
  await quota.releaseStorageReservation(winningId, 'test-release-retry');
  state = (await quotaRef.get()).data();
  assert.equal(state.reservedBytes, 0, 'releasing twice should only release once');

  const uploadId = await reserve('uploader_c', 'asset_c', 1_000);
  await quota.completeStorageReservation(uploadId, 600);
  await quota.completeStorageReservation(uploadId, 600);
  state = (await quotaRef.get()).data();
  assert.equal(state.usedBytes, 600, 'successful finalization should count actual bytes once');
  assert.equal(state.reservedBytes, 0);

  const objectKey = 'products/quarantine/uploader_c/asset_c';
  let objectPresent = true;
  let failDelete = true;
  gateway.r2Head = async () => objectPresent ? { key: objectKey, size: 600 } : null;
  gateway.r2Delete = async () => {
    if (failDelete) throw new Error('simulated R2 outage');
    const existed = objectPresent;
    objectPresent = false;
    return { existed };
  };
  await assert.rejects(() => quota.deleteStoredObject(objectKey, 'uploader_c', 'test-failed-delete'));
  state = (await quotaRef.get()).data();
  assert.equal(state.usedBytes, 600, 'failed deletion must preserve counted bytes');
  failDelete = false;
  await quota.deleteStoredObject(objectKey, 'uploader_c', 'test-delete');
  await quota.deleteStoredObject(objectKey, 'uploader_c', 'test-delete-retry');
  state = (await quotaRef.get()).data();
  assert.equal(state.usedBytes, 0, 'verified deletion should restore capacity exactly once');
  assert.equal(state.remainingBytes, quota.R2_STORAGE_LIMIT_BYTES);

  const collections = ['system_config', 'uploadReservations', 'mediaAssets', 'storageObjects', 'storageAudit'];
  for (const name of collections) {
    const docs = await db.collection(name).get();
    for (const doc of docs.docs) await doc.ref.delete();
  }
  await deleteApp(app);
  console.log('R2 quota emulator smoke checks passed (concurrency, rejection, release, finalize, failed delete, retry-safe delete).');
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
