const assert = require("node:assert/strict");
const { createHash } = require("node:crypto");
const { verifyStoredPanoramaDerivative } = require("../functions/lib/panorama_derivative_validation.js");

const bytes = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x02, 0x11, 0x22, 0xff, 0xd9]);
const sha256 = createHash("sha256").update(bytes).digest("hex");
const reservationId = "reservation-123456789";
const uid = "owner_123";
const tourId = 19;
const nodeId = 2;
const revisionId = "0123456789abcdef0123456789abcdef";
const objectKey = `tours/derivatives/${uid}/${tourId}/${nodeId}/${revisionId}_${sha256}.jpg`;
const input = {
  uid, tourId, nodeId, revisionId, reservationId, expectedSha256: sha256,
  maxBytes: 50 * 1024 * 1024,
  head: { key: objectKey, size: bytes.length, contentType: "image/jpeg", reservationId, uid, mediaType: "panorama-derivative" },
  bytes,
};

assert.deepEqual(verifyStoredPanoramaDerivative(input), { objectKey, actualBytes: bytes.length, sha256 });
for (const invalid of [
  { ...input, head: { ...input.head, uid: "other-owner" } },
  { ...input, head: { ...input.head, contentType: "image/png" } },
  { ...input, head: { ...input.head, size: bytes.length + 1 } },
  { ...input, head: { ...input.head, key: input.head.key.replace(sha256, "f".repeat(64)) } },
  { ...input, bytes: Buffer.from([0xff, 0xd8, 0xff, 1, 2, 0xff, 0xd9]) },
]) {
  assert.throws(() => verifyStoredPanoramaDerivative(invalid));
}

console.log("Panorama derivative verification checks passed (immutable key, owner, reservation, content type, actual size, JPEG structure, SHA-256).");
