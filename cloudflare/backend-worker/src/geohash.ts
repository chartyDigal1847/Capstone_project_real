export function geohash(lat: number, lng: number): string {
  const alphabet = "0123456789bcdefghjkmnpqrstuvwxyz";
  let south = -90, north = 90, west = -180, east = 180, even = true, bits = 0, value = 0, result = "";
  while (result.length < 4) {
    const midpoint = even ? (west + east) / 2 : (south + north) / 2;
    const upper = (even ? lng : lat) >= midpoint;
    value = (value << 1) | (upper ? 1 : 0);
    if (even) upper ? west = midpoint : east = midpoint;
    else upper ? south = midpoint : north = midpoint;
    even = !even;
    if (++bits === 5) { result += alphabet[value]; value = 0; bits = 0; }
  }
  return result;
}
