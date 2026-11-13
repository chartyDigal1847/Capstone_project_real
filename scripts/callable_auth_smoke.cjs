const assert = require("node:assert/strict");

const projectId = process.env.GCLOUD_PROJECT || "demo-localspot";
const region = "asia-southeast1";
const functions = [
  "approveStoreApplication",
  "manageStoreMembership",
  "reviewStoreApplication",
  "submitStoreApplication",
  "archiveStoreListing",
  "createStoreListing",
  "updateStoreListing",
  "createStorePromotion",
  "reviewStorePromotion",
  "startVendorLocationSession",
  "stopVendorLocationSession",
  "updateVendorLocationSession",
  "resolveReport",
];

async function main() {
  for (const name of functions) {
    const response = await fetch(`http://127.0.0.1:5001/${projectId}/${region}/${name}`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ data: {} }),
    });
    const body = await response.json().catch(() => null);
    assert.equal(response.status, 401, `${name} should reject a call without Firebase Auth: ${JSON.stringify(body)}`);
    assert.equal(body?.error?.status, "UNAUTHENTICATED", `${name} returned an unexpected error: ${JSON.stringify(body)}`);
  }
  console.log(`Callable Auth smoke checks passed (${functions.length} protected callables reject unauthenticated requests)`);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
