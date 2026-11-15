import { createHash } from "node:crypto";
import { HttpsError } from "firebase-functions/v2/https";

export interface StoredDerivativeHead {
  key: string;
  size: number;
  contentType: string;
  reservationId: string | null;
  uid: string | null;
  mediaType: string | null;
}

export function verifyStoredPanoramaDerivative(input: {
  uid: string;
  tourId: number;
  nodeId: number;
  revisionId: string;
  reservationId: string;
  expectedSha256: string;
  maxBytes: number;
  head: StoredDerivativeHead;
  bytes: Uint8Array;
}): { objectKey: string; actualBytes: number; sha256: string } {
  const expectedKey = `tours/derivatives/${input.uid}/${input.tourId}/${input.nodeId}/${input.revisionId}_${input.expectedSha256}.jpg`;
  const keyPattern = /^tours\/derivatives\/([A-Za-z0-9_-]{1,128})\/([1-9][0-9]{0,15})\/([1-9][0-9]{0,15})\/([A-Za-z0-9_-]{16,64})_([a-f0-9]{64})\.jpg$/;
  const match = keyPattern.exec(input.head.key);
  if (!match || input.head.key !== expectedKey || match[1] !== input.uid || Number(match[2]) !== input.tourId ||
      Number(match[3]) !== input.nodeId || match[4] !== input.revisionId || match[5] !== input.expectedSha256) {
    throw new HttpsError("data-loss", "The R2 derivative key does not match its immutable reservation.");
  }
  if (!Number.isSafeInteger(input.head.size) || input.head.size <= 0 || input.head.size > input.maxBytes ||
      input.head.contentType !== "image/jpeg" || input.head.reservationId !== input.reservationId ||
      input.head.uid !== input.uid || input.head.mediaType !== "panorama-derivative") {
    throw new HttpsError("failed-precondition", "The R2 object metadata does not match its owner reservation.");
  }
  if (input.bytes.length !== input.head.size || input.bytes.length < 5 ||
      input.bytes[0] !== 0xff || input.bytes[1] !== 0xd8 || input.bytes[2] !== 0xff ||
      input.bytes[input.bytes.length - 2] !== 0xff || input.bytes[input.bytes.length - 1] !== 0xd9) {
    throw new HttpsError("failed-precondition", "The stored derivative is not a complete JPEG of the reported size.");
  }
  const sha256 = createHash("sha256").update(input.bytes).digest("hex");
  if (sha256 !== input.expectedSha256) {
    throw new HttpsError("failed-precondition", "The stored derivative SHA-256 does not match its immutable key.");
  }
  return { objectKey: expectedKey, actualBytes: input.bytes.length, sha256 };
}
