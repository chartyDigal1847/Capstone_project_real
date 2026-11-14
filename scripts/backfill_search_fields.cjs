const path = require("node:path");
const { createRequire } = require("node:module");
const requireFunctions = createRequire(path.resolve(__dirname, "../functions/package.json"));
const { initializeApp } = requireFunctions("firebase-admin/app");
const { FieldPath, FieldValue, getFirestore } = requireFunctions("firebase-admin/firestore");

const BASE32 = "0123456789bcdefghjkmnpqrstuvwxyz";
const PAGE_SIZE = 250;
const BATCH_LIMIT = 400;

function argsFrom(argv) {
  const result = { apply: false, project: "", confirmProject: "", collections: ["products", "stores", "listings"] };
  for (const arg of argv) {
    if (arg === "--apply") result.apply = true;
    else if (arg.startsWith("--project=")) result.project = arg.slice(10);
    else if (arg.startsWith("--confirm-project=")) result.confirmProject = arg.slice(18);
    else if (arg.startsWith("--collections=")) result.collections = arg.slice(14).split(",").filter(Boolean);
    else throw new Error(`Unknown argument: ${arg}`);
  }
  return result;
}

function normalize(value) {
  return String(value ?? "").toLowerCase().replace(/[^a-z0-9]+/g, " ").trim().replace(/\s+/g, " ");
}

function searchPrefixes(values) {
  const prefixes = new Set();
  const variants = values
    .map(normalize)
    .filter(Boolean)
    .flatMap((phrase) => {
      const words = phrase.split(" ");
      return words.map((_, start) => words.slice(start).join(" "));
    });
  const add = (value) => {
    const bounded = value.slice(0, 80);
    if (bounded.length >= 2) prefixes.add(bounded);
  };
  for (const variant of variants) {
    add(variant);
    for (const word of variant.split(" ")) add(word);
    if (prefixes.size >= 200) return [...prefixes].slice(0, 200);
  }
  for (let length = 2; length <= 80; length++) {
    for (const variant of variants) {
      if (variant.length >= length) add(variant.slice(0, length));
      if (prefixes.size >= 200) return [...prefixes].slice(0, 200);
    }
  }
  return [...prefixes];
}

function encodeGeohash(latitude, longitude, precision = 4) {
  if (!Number.isFinite(latitude) || latitude < -90 || latitude > 90 ||
      !Number.isFinite(longitude) || longitude < -180 || longitude > 180) return null;
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
      hash += BASE32[value];
      bits = 0;
      value = 0;
    }
  }
  return hash;
}

function updatedFields(collection, data) {
  if (collection === "products") {
    const attributes = data.attributes && typeof data.attributes === "object" ? Object.values(data.attributes) : [];
    return {
      searchPrefixes: searchPrefixes([
        data.name,
        data.brand,
        data.category,
        ...attributes,
        ...(Array.isArray(data.aliases) ? data.aliases : []),
      ]),
    };
  }
  const lat = typeof data.lat === "number" ? data.lat : NaN;
  const lng = typeof data.lng === "number" ? data.lng : NaN;
  const geohash = encodeGeohash(lat, lng);
  return geohash ? { geohash } : null;
}

async function backfillCollection(db, collection, apply) {
  let cursor = null;
  let scanned = 0;
  let changed = 0;
  while (true) {
    let query = db.collection(collection).orderBy(FieldPath.documentId()).limit(PAGE_SIZE);
    if (cursor) query = query.startAfter(cursor);
    const page = await query.get();
    if (page.empty) break;
    const updates = [];
    for (const doc of page.docs) {
      const fields = updatedFields(collection, doc.data());
      if (!fields) continue;
      const same = collection === "products"
        ? JSON.stringify(doc.data().searchPrefixes ?? []) === JSON.stringify(fields.searchPrefixes)
        : doc.data().geohash === fields.geohash;
      if (!same) updates.push([doc.ref, fields]);
    }
    if (apply) {
      for (let offset = 0; offset < updates.length; offset += BATCH_LIMIT) {
        const batch = db.batch();
        for (const [ref, fields] of updates.slice(offset, offset + BATCH_LIMIT)) batch.update(ref, fields);
        await batch.commit();
      }
    }
    scanned += page.size;
    changed += updates.length;
    cursor = page.docs[page.docs.length - 1];
    console.log(`${collection}: scanned ${scanned}, ${apply ? "updated" : "would update"} ${changed}`);
    if (page.size < PAGE_SIZE) break;
  }
  return { collection, scanned, changed };
}

async function main() {
  const options = argsFrom(process.argv.slice(2));
  if (!options.project) throw new Error("Pass --project=<firebase-project-id>. The script never infers a write target.");
  if (options.apply && options.confirmProject !== options.project) {
    throw new Error("Writes require --confirm-project to exactly match --project.");
  }
  const allowed = new Set(["products", "stores", "listings"]);
  if (options.collections.some((collection) => !allowed.has(collection))) {
    throw new Error("Supported collections are products, stores and listings.");
  }
  const emulator = Boolean(process.env.FIRESTORE_EMULATOR_HOST);
  const app = initializeApp({ projectId: options.project }, `backfill-search-${Date.now()}`);
  const db = getFirestore(app);
  try {
    console.log(`${options.apply ? "APPLY" : "DRY RUN"} target=${options.project}${emulator ? ` emulator=${process.env.FIRESTORE_EMULATOR_HOST}` : ""}`);
    const results = [];
    for (const collection of options.collections) results.push(await backfillCollection(db, collection, options.apply));
    if (options.apply && options.collections.includes("products")) {
      await db.collection("systemMetadata").doc("searchPrefixIndex").set({
        ready: true,
        version: 2,
        updatedAt: FieldValue.serverTimestamp(),
      });
      console.log("Marked the product prefix index ready after the complete products scan.");
    }
    console.log(JSON.stringify({ mode: options.apply ? "apply" : "dry-run", project: options.project, results }, null, 2));
  } finally {
    await db.terminate();
    await app.delete();
  }
}

main().catch((error) => {
  console.error(error.message ?? error);
  process.exitCode = 1;
});
