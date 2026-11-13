const mapboxAccessToken = String.fromEnvironment('ACCESS_TOKEN');

bool get hasMapboxPublicToken =>
    mapboxAccessToken.startsWith('pk.') && !mapboxAccessToken.startsWith('sk.');
