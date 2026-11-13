const assert = require("node:assert/strict");
const { execFileSync, spawnSync } = require("node:child_process");
const { randomUUID } = require("node:crypto");
const path = require("node:path");
const { createRequire } = require("node:module");

const emulatorHost = process.env.FIRESTORE_EMULATOR_HOST;
if (!emulatorHost) {
  throw new Error("This smoke test requires FIRESTORE_EMULATOR_HOST.");
}

const projectId = process.env.GCLOUD_PROJECT || "demo-localspot";
const requireFunctions = createRequire(path.resolve(__dirname, "../functions/package.json"));
const { initializeApp } = requireFunctions("firebase-admin/app");
const { getFirestore, Timestamp } = requireFunctions("firebase-admin/firestore");
const app = initializeApp({ projectId }, "backfill-search-smoke");
const db = getFirestore(app);
const suffix = randomUUID();
const productId = `backfill-product-${suffix}`;
const storeId = `backfill-store-${suffix}`;
const listingId = `backfill-listing-${suffix}`;
const metadataRef = db.collection("systemMetadata").doc("searchPrefixIndex");
const script = path.join(__dirname, "backfill_search_fields.cjs");
const commonArgs = [
  script,
  `--project=${projectId}`,
  "--collections=products,stores,listings",
];

function runBackfill(args) {
  return execFileSync(process.execPath, [...commonArgs, ...args], {
    cwd: path.resolve(__dirname, ".."),
    env: process.env,
    encoding: "utf8",
  });
}

function encodeGeohash(latitude, longitude, precision = 4) {
  const alphabet = "0123456789bcdefghjkmnpqrstuvwxyz";
  let south = -90;
  let north = 90;
  let west = -180;
  let east = 180;
  let even = true;
  let bits = 0;
  let value = 0;
  let hash = "";
  while (hash.length < precision) {
    const midpoint = even ? (west + east) / 2 : (south + north) / 2;
    const coordinate = even ? longitude : latitude;
    const upper = coordinate >= midpoint;
    value = (value << 1) | (upper ? 1 : 0);
    if (even) upper ? west = midpoint : east = midpoint;
    else upper ? south = midpoint : north = midpoint;
    even = !even;
    bits++;
    if (bits === 5) {
      hash += alphabet[value];
      bits = 0;
      value = 0;
    }
  }
  return hash;
}

async function main() {
  const productRef = db.collection("products").doc(productId);
  const storeRef = db.collection("stores").doc(storeId);
  const listingRef = db.collection("listings").doc(listingId);
  const latitude = 14.6195;
  const longitude = 121.0568;

  try {
    await Promise.all([
      productRef.set({
        numericId: Date.now() & 0x7fffffff,
        name: "Industrial steel clamp",
        brand: "Workshop Kit",
        category: "Hardware",
        aliases: ["pipe vice"],
        attributes: { material: "steel" },
      }),
      storeRef.set({
        numericId: (Date.now() + 1) & 0x7fffffff,
        lat: latitude,
        lng: longitude,
      }),
      listingRef.set({
        numericId: (Date.now() + 2) & 0x7fffffff,
        lat: latitude,
        lng: longitude,
      }),
      metadataRef.delete(),
    ]);

    const dryRun = runBackfill([]);
    assert.match(dryRun, /"mode": "dry-run"/);
    assert.equal((await productRef.get()).data().searchPrefixes, undefined);
    assert.equal((await storeRef.get()).data().geohash, undefined);
    assert.equal((await listingRef.get()).data().geohash, undefined);
    assert.equal((await metadataRef.get()).exists, false);

    const rejectedApply = spawnSync(
      process.execPath,
      [...commonArgs, "--apply", "--confirm-project=wrong-project"],
      { cwd: path.resolve(__dirname, ".."), env: process.env, encoding: "utf8" },
    );
    assert.notEqual(rejectedApply.status, 0);
    assert.match(
      `${rejectedApply.stdout}${rejectedApply.stderr}`,
      /Writes require --confirm-project to exactly match --project/,
    );
    assert.equal((await productRef.get()).data().searchPrefixes, undefined);

    const apply = runBackfill(["--apply", `--confirm-project=${projectId}`]);
    assert.match(apply, /"mode": "apply"/);
    const product = (await productRef.get()).data();
    for (const term of ["industrial", "clamp", "steel", "pipe vice"]) {
      assert.ok(product.searchPrefixes.includes(term), `missing prefix ${term}`);
    }
    const expectedHash = encodeGeohash(latitude, longitude);
    assert.equal((await storeRef.get()).data().geohash, expectedHash);
    assert.equal((await listingRef.get()).data().geohash, expectedHash);
    const indexState = (await metadataRef.get()).data();
    assert.equal(indexState.ready, true);
    assert.equal(indexState.version, 2);
    assert.ok(indexState.updatedAt instanceof Timestamp);

    const repeat = runBackfill(["--apply", `--confirm-project=${projectId}`]);
    assert.match(repeat, /"changed": 0/);
    console.log("Search/geohash backfill smoke checks passed (dry-run, project guard, apply, readiness, idempotency)");
  } finally {
    await Promise.all([
      productRef.delete(),
      storeRef.delete(),
      listingRef.delete(),
      metadataRef.delete(),
    ]);
    await db.terminate();
    await app.delete();
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
