const assert = require("node:assert/strict");
const { validatePanoramaReviewInput } = require("../functions/lib/panorama_privacy.js");

const valid = {
  tourId: 91,
  nodeId: 2,
  derivativeSha256: "a".repeat(64),
  processingVersion: "localspot-panorama-local-v2",
  inspectedDirections: Array.from({ length: 48 }, (_, index) => 47 - index),
  acknowledgedMissRisk: true,
  acknowledgedManualInspection: true,
  ownerUid: "attacker-supplied-uid-is-ignored-by-callable",
};
const accepted = validatePanoramaReviewInput(valid);
assert.equal(accepted.tourId, 91);
assert.equal(accepted.inspectedDirections.length, 48);
assert.equal(accepted.inspectedDirections[0], 0);
assert.equal(Object.hasOwn(accepted, "ownerUid"), false);

for (const invalid of [
  { ...valid, inspectedDirections: valid.inspectedDirections.slice(1) },
  { ...valid, inspectedDirections: [...valid.inspectedDirections.slice(0, 47), 46] },
  { ...valid, acknowledgedMissRisk: false },
  { ...valid, derivativeSha256: "not-a-digest" },
  { ...valid, processingVersion: "unknown" },
]) {
  assert.throws(() => validatePanoramaReviewInput(invalid));
}

console.log("Panorama owner-review validation checks passed (48 unique directions, acknowledgements, digest, version, caller UID exclusion).");
