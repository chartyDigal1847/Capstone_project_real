export const MAX_BYTES = 8 * 1024 * 1024;
export const FORMATS = [
  { mime: "image/jpeg", extension: "jpg", signature: (b: Buffer) => b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff },
  { mime: "image/png", extension: "png", signature: (b: Buffer) => b.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10])) },
  { mime: "image/webp", extension: "webp", signature: (b: Buffer) => b.toString("ascii", 0, 4) === "RIFF" && b.toString("ascii", 8, 12) === "WEBP" },
];

function stripJpegMetadata(input: Buffer): Buffer | null {
  if (input.length < 4 || input[0] !== 0xff || input[1] !== 0xd8) return null;
  const chunks: Buffer[] = [input.subarray(0, 2)];
  let offset = 2;
  while (offset < input.length) {
    const start = offset;
    if (input[offset++] !== 0xff) return null;
    while (offset < input.length && input[offset] === 0xff) offset++;
    if (offset >= input.length) return null;
    const marker = input[offset++];
    if (marker === 0xd9) {
      chunks.push(input.subarray(start, offset));
      return Buffer.concat(chunks);
    }
    if (marker === 0x01 || (marker >= 0xd0 && marker <= 0xd8)) {
      chunks.push(input.subarray(start, offset));
      continue;
    }
    if (offset + 2 > input.length) return null;
    const segmentLength = input.readUInt16BE(offset);
    const end = offset + segmentLength;
    if (segmentLength < 2 || end > input.length) return null;
    if (marker === 0xda) {
      chunks.push(input.subarray(start, end));
      let scan = end;
      while (scan < input.length) {
        if (input[scan] !== 0xff) {
          scan++;
          continue;
        }
        const markerStart = scan++;
        while (scan < input.length && input[scan] === 0xff) scan++;
        if (scan >= input.length) return null;
        const scanMarker = input[scan];
        if (scanMarker === 0x00 || (scanMarker >= 0xd0 && scanMarker <= 0xd7)) {
          scan++;
          continue;
        }
        chunks.push(input.subarray(end, markerStart));
        offset = markerStart;
        break;
      }
      if (scan >= input.length) return null;
      continue;
    }
    const isPrivateMetadata = (marker >= 0xe1 && marker <= 0xed) || marker === 0xef || marker === 0xfe;
    if (!isPrivateMetadata) chunks.push(input.subarray(start, end));
    offset = end;
  }
  return null;
}

function stripPngMetadata(input: Buffer): Buffer | null {
  const signature = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
  if (input.length < 20 || !input.subarray(0, 8).equals(signature)) return null;
  const chunks: Buffer[] = [input.subarray(0, 8)];
  let offset = 8;
  let foundEnd = false;
  while (offset + 12 <= input.length) {
    const length = input.readUInt32BE(offset);
    const end = offset + 12 + length;
    if (end > input.length) return null;
    const type = input.toString("ascii", offset + 4, offset + 8);
    // PNG critical chunks start with an uppercase letter. Ancillary chunks may
    // contain EXIF, textual, time, location or other identifying metadata.
    if (type[0] >= "A" && type[0] <= "Z") chunks.push(input.subarray(offset, end));
    offset = end;
    if (type === "IEND") {
      foundEnd = true;
      break;
    }
  }
  return foundEnd && offset === input.length ? Buffer.concat(chunks) : null;
}

function stripWebpMetadata(input: Buffer): Buffer | null {
  if (input.length < 20 || input.toString("ascii", 0, 4) !== "RIFF" ||
      input.readUInt32LE(4) !== input.length - 8 || input.toString("ascii", 8, 12) !== "WEBP") return null;
  const chunks: Buffer[] = [];
  let offset = 12;
  let hasImage = false;
  while (offset + 8 <= input.length) {
    const type = input.toString("ascii", offset, offset + 4);
    const size = input.readUInt32LE(offset + 4);
    const end = offset + 8 + size + (size & 1);
    if (end > input.length) return null;
    if (type === "ANIM" || type === "ANMF") return null;
    const chunk = Buffer.from(input.subarray(offset, end));
    if (type === "VP8 " || type === "VP8L") hasImage = true;
    if (type === "VP8X") {
      if (size !== 10) return null;
      chunk[8] &= ~(0x20 | 0x08 | 0x04); // Remove ICC, EXIF and XMP feature flags.
      chunks.push(chunk);
    } else if (type !== "EXIF" && type !== "XMP " && type !== "ICCP") {
      chunks.push(chunk);
    }
    offset = end;
  }
  if (!hasImage || offset !== input.length) return null;
  const body = Buffer.concat([Buffer.from("WEBP", "ascii"), ...chunks]);
  const header = Buffer.alloc(8);
  header.write("RIFF", 0, "ascii");
  header.writeUInt32LE(body.length, 4);
  return Buffer.concat([header, body]);
}

export function stripImageMetadata(input: Buffer, mime: string): Buffer | null {
  if (mime === "image/jpeg") return stripJpegMetadata(input);
  if (mime === "image/png") return stripPngMetadata(input);
  if (mime === "image/webp") return stripWebpMetadata(input);
  return null;
}

