const BASE32 = "0123456789bcdefghjkmnpqrstuvwxyz";

export function encodeGeohash(latitude: number, longitude: number, precision = 4): string {
  if (!Number.isFinite(latitude) || latitude < -90 || latitude > 90 ||
      !Number.isFinite(longitude) || longitude < -180 || longitude > 180) {
    throw new RangeError("Coordinates are outside their valid ranges.");
  }
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
