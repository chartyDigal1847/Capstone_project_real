export const MAX_IMAGE_BYTES = 8 * 1024 * 1024;
export const IMAGE_FORMATS = [
  { mime: "image/jpeg", extension: "jpg", signature: (bytes: Uint8Array) => bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff },
  { mime: "image/png", extension: "png", signature: (bytes: Uint8Array) => [137, 80, 78, 71, 13, 10, 26, 10].every((value, index) => bytes[index] === value) },
  { mime: "image/webp", extension: "webp", signature: (bytes: Uint8Array) => ascii(bytes, 0, 4) === "RIFF" && ascii(bytes, 8, 12) === "WEBP" },
];

function ascii(bytes: Uint8Array, from: number, to: number): string { return new TextDecoder().decode(bytes.subarray(from, to)); }
function join(chunks: Uint8Array[]): Uint8Array {
  const result = new Uint8Array(chunks.reduce((sum, item) => sum + item.length, 0));
  let offset = 0;
  for (const chunk of chunks) { result.set(chunk, offset); offset += chunk.length; }
  return result;
}

function jpeg(bytes: Uint8Array): Uint8Array | null {
  if (bytes.length < 4 || bytes[0] !== 0xff || bytes[1] !== 0xd8) return null;
  const chunks = [bytes.subarray(0, 2)];
  let offset = 2;
  while (offset < bytes.length) {
    const start = offset;
    if (bytes[offset++] !== 0xff) return null;
    while (offset < bytes.length && bytes[offset] === 0xff) offset++;
    if (offset >= bytes.length) return null;
    const marker = bytes[offset++];
    if (marker === 0xd9) { chunks.push(bytes.subarray(start, offset)); return join(chunks); }
    if (marker === 0x01 || (marker >= 0xd0 && marker <= 0xd8)) { chunks.push(bytes.subarray(start, offset)); continue; }
    if (offset + 2 > bytes.length) return null;
    const length = (bytes[offset] << 8) | bytes[offset + 1], end = offset + length;
    if (length < 2 || end > bytes.length) return null;
    if (marker === 0xda) {
      chunks.push(bytes.subarray(start, end));
      let scan = end;
      while (scan < bytes.length) {
        if (bytes[scan] !== 0xff) { scan++; continue; }
        const markerStart = scan++;
        while (scan < bytes.length && bytes[scan] === 0xff) scan++;
        if (scan >= bytes.length) return null;
        const next = bytes[scan];
        if (next === 0x00 || (next >= 0xd0 && next <= 0xd7)) { scan++; continue; }
        chunks.push(bytes.subarray(end, markerStart)); offset = markerStart; break;
      }
      if (scan >= bytes.length) return null;
      continue;
    }
    const metadata = (marker >= 0xe1 && marker <= 0xed) || marker === 0xef || marker === 0xfe;
    if (!metadata) chunks.push(bytes.subarray(start, end));
    offset = end;
  }
  return null;
}

function png(bytes: Uint8Array): Uint8Array | null {
  if (bytes.length < 20 || !IMAGE_FORMATS[1].signature(bytes)) return null;
  const chunks = [bytes.subarray(0, 8)];
  let offset = 8, foundEnd = false;
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  while (offset + 12 <= bytes.length) {
    const length = view.getUint32(offset, false), end = offset + 12 + length;
    if (end > bytes.length) return null;
    const type = ascii(bytes, offset + 4, offset + 8);
    if (type[0] >= "A" && type[0] <= "Z") chunks.push(bytes.subarray(offset, end));
    offset = end;
    if (type === "IEND") { foundEnd = true; break; }
  }
  return foundEnd && offset === bytes.length ? join(chunks) : null;
}

function webp(bytes: Uint8Array): Uint8Array | null {
  if (bytes.length < 20 || !IMAGE_FORMATS[2].signature(bytes)) return null;
  const input = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  if (input.getUint32(4, true) !== bytes.length - 8) return null;
  const chunks: Uint8Array[] = [];
  let offset = 12, hasImage = false;
  while (offset + 8 <= bytes.length) {
    const type = ascii(bytes, offset, offset + 4), size = input.getUint32(offset + 4, true), end = offset + 8 + size + (size & 1);
    if (end > bytes.length || type === "ANIM" || type === "ANMF") return null;
    const chunk = bytes.slice(offset, end);
    if (type === "VP8 " || type === "VP8L") hasImage = true;
    if (type === "VP8X") {
      if (size !== 10) return null;
      chunk[8] &= ~(0x20 | 0x08 | 0x04);
      chunks.push(chunk);
    } else if (type !== "EXIF" && type !== "XMP " && type !== "ICCP") chunks.push(chunk);
    offset = end;
  }
  if (!hasImage || offset !== bytes.length) return null;
  const body = join([new TextEncoder().encode("WEBP"), ...chunks]);
  const header = new Uint8Array(8); header.set(new TextEncoder().encode("RIFF")); new DataView(header.buffer).setUint32(4, body.length, true);
  return join([header, body]);
}

export function stripImageMetadata(bytes: Uint8Array, mime: string): Uint8Array | null {
  if (mime === "image/jpeg") return jpeg(bytes);
  if (mime === "image/png") return png(bytes);
  if (mime === "image/webp") return webp(bytes);
  return null;
}
