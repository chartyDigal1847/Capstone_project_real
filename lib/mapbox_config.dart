const _publicMapboxToken = String.fromEnvironment('PUBLIC_MAPBOX_ACCESS_TOKEN');
const _legacyMapboxToken = String.fromEnvironment('ACCESS_TOKEN');

// Keep accepting the old define name so an existing run configuration does
// not silently disable Mapbox after the safer, explicit name was introduced.
final mapboxAccessToken =
    (_publicMapboxToken.trim().isNotEmpty
            ? _publicMapboxToken
            : _legacyMapboxToken)
        .trim();

bool get hasMapboxPublicToken =>
    mapboxAccessToken.startsWith('pk.') && !mapboxAccessToken.startsWith('sk.');
