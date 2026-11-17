# Offline Philippine location picker

`assets/data/ph_psgc_locations.json` is bundled into the Android app. The store form uses it to search cities/municipalities and their barangays without network geocoding.

## Source and attribution

- Administrative names and PSGC codes: Philippine Statistics Authority (PSA), Philippine Standard Geographic Code, Q3 2026. Credit PSA when displaying this data.
- Barangay map points: `Tenasia/ph-psgc` 2026-Q2, derived from the MIT-licensed `faeldon/philippines-json-maps` boundaries. The official Q3 2026 PSA correction from “Lambangan” to “Lambagan” in Cabanglasan, Bukidnon, is applied in the bundled data.
- Dataset source and format notes: https://github.com/Tenasia/ph-psgc

The data is a list of administrative areas, not street addresses or store listings. Barangay map points are approximate starting locations; owners must use the map pin to mark the exact storefront.

## Updating the data

The repository currently provides a compact downloadable index based on PSA 2026-Q2. The project maintains the Q3 2026 correction in the app data until its next quarterly dataset release is imported. Keep PSGC codes as strings so leading zeroes are preserved. Keep this source notice and the map-boundary MIT license notice with future point-data updates.
