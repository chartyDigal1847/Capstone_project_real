const path = require("node:path");
const { createRequire } = require("node:module");
const requireFunctions = createRequire(path.resolve(__dirname, "../functions/package.json"));
const { initializeApp } = requireFunctions("firebase-admin/app");
const { FieldPath, getFirestore } = requireFunctions("firebase-admin/firestore");

const PAGE_SIZE = 250;
const BATCH_LIMIT = 400;
const IMAGE_COLLECTIONS = ["products", "stores", "tours"];

function parseArgs(argv) {
  const options = { apply: false, project: "", confirmProject: "" };
  for (const arg of argv) {
    if (arg === "--apply") options.apply = true;
    else if (arg.startsWith("--project=")) options.project = arg.slice(10);
    else if (arg.startsWith("--confirm-project=")) options.confirmProject = arg.slice(18);
    else throw new Error(`Unknown argument: ${arg}`);
  }
  return options;
}

function isUnsplash(value) {
  if (typeof value !== "string") return false;
  try {
    const host = new URL(value).hostname.toLowerCase();
    return host === "images.unsplash.com" || host === "source.unsplash.com";
  } catch (_) {
    return false;
  }
}

function imageCleanup(collection, data) {
  const fields = {};
  if (collection === "tours") {
    if (!Array.isArray(data.nodes)) return null;
    let changed = false;
    const nodes = data.nodes.map((node) => {
      if (!node || typeof node !== "object" || !isUnsplash(node.image)) return node;
      changed = true;
      return { ...node, image: "" };
    });
    if (changed) fields.nodes = nodes;
  } else if (isUnsplash(data.image)) {
    fields.image = "";
  }
  return Object.keys(fields).length ? fields : null;
}

async function scanCollection(db, collection, apply) {
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
      const fields = imageCleanup(collection, doc.data());
      if (fields) updates.push([doc.ref, fields]);
    }
    if (apply) {
      for (let offset = 0; offset < updates.length; offset += BATCH_LIMIT) {
        const batch = db.batch();
        for (const [ref, fields] of updates.slice(offset, offset + BATCH_LIMIT)) {
          batch.update(ref, fields);
        }
        await batch.commit();
      }
    }
    scanned += page.size;
    changed += updates.length;
    cursor = page.docs[page.docs.length - 1];
    console.log(`${collection}: scanned ${scanned}, ${apply ? "cleared" : "would clear"} ${changed}`);
    if (page.size < PAGE_SIZE) break;
  }
  return { collection, scanned, changed };
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  if (!options.project) throw new Error("Pass --project=<firebase-project-id>; the script never infers a write target.");
  if (options.apply && options.confirmProject !== options.project) {
    throw new Error("Writes require --confirm-project to exactly match --project.");
  }
  const app = initializeApp({ projectId: options.project }, `remove-unsplash-${Date.now()}`);
  const db = getFirestore(app);
  try {
    const emulator = Boolean(process.env.FIRESTORE_EMULATOR_HOST);
    console.log(`${options.apply ? "APPLY" : "DRY RUN"} target=${options.project}${emulator ? ` emulator=${process.env.FIRESTORE_EMULATOR_HOST}` : ""}`);
    const results = [];
    for (const collection of IMAGE_COLLECTIONS) {
      results.push(await scanCollection(db, collection, options.apply));
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
