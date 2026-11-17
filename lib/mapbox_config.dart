const mapboxAccessToken = String.fromEnvironment(
  'PUBLIC_MAPBOX_ACCESS_TOKEN',
);

bool get hasMapboxPublicToken =>
    mapboxAccessToken.startsWith('pk.') && !mapboxAccessToken.startsWith('sk.');
