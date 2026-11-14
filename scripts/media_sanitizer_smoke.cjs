const assert = require("node:assert/strict");
const { stripImageMetadata } = require("../functions/lib/image_sanitizer.js");

function pngChunk(type, data) {
  const length = Buffer.alloc(4);
  length.writeUInt32BE(data.length);
  return Buffer.concat([length, Buffer.from(type), data, Buffer.alloc(4)]);
}

function webpChunk(type, data) {
  const size = Buffer.alloc(4);
  size.writeUInt32LE(data.length);
  return Buffer.concat([Buffer.from(type), size, data, ...(data.length % 2 ? [Buffer.alloc(1)] : [])]);
}

const jpeg = Buffer.from([
  0xff, 0xd8,
  0xff, 0xe1, 0x00, 0x08, 0x45, 0x58, 0x49, 0x46, 0x00, 0x00,
  0xff, 0xda, 0x00, 0x02, 0x11, 0x22, 0xff, 0xd9,
]);
const cleanJpeg = stripImageMetadata(jpeg, "image/jpeg");
assert.ok(cleanJpeg);
assert.equal(cleanJpeg.includes(Buffer.from("EXIF")), false);
assert.equal(cleanJpeg[0], 0xff);

const png = Buffer.concat([
  Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
  pngChunk("IHDR", Buffer.alloc(13)),
  pngChunk("tEXt", Buffer.from("GPS-location")),
  pngChunk("IDAT", Buffer.from([1, 2, 3])),
  pngChunk("IEND", Buffer.alloc(0)),
]);
const cleanPng = stripImageMetadata(png, "image/png");
assert.ok(cleanPng);
assert.equal(cleanPng.includes(Buffer.from("GPS-location")), false);
assert.equal(cleanPng.includes(Buffer.from("IDAT")), true);

const webpChunks = Buffer.concat([
  webpChunk("VP8X", Buffer.from([0x2c, 0, 0, 0, 0, 0, 0, 0, 0, 0])),
  webpChunk("EXIF", Buffer.from("GPS")),
  webpChunk("VP8 ", Buffer.from([1, 2, 3, 4])),
]);
const webpHeader = Buffer.alloc(8);
webpHeader.write("RIFF", 0, "ascii");
webpHeader.writeUInt32LE(4 + webpChunks.length, 4);
const webp = Buffer.concat([webpHeader, Buffer.from("WEBP"), webpChunks]);
const cleanWebp = stripImageMetadata(webp, "image/webp");
assert.ok(cleanWebp);
assert.equal(cleanWebp.includes(Buffer.from("GPS")), false);
assert.equal(cleanWebp.includes(Buffer.from("EXIF")), false);
assert.equal(cleanWebp[20] & 0x2c, 0);

assert.equal(stripImageMetadata(Buffer.from("not an image"), "image/jpeg"), null);
assert.equal(stripImageMetadata(Buffer.from("x"), "image/gif"), null);
console.log("Image metadata sanitizer smoke checks passed (JPEG, PNG, WebP, malformed, unsupported).");
