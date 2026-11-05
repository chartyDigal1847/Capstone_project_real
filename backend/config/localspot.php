<?php

return [
    /*
    | Optional OSRM-compatible routing base, for example https://router.example/osrm.
    | Leave empty to return a local straight-line preview (used in tests and offline).
    | Do not point production at the public project-osrm.org demo server.
    |
    | Supported providers:
    |   - osrm (default): standard OSRM HTTP API
    |   - openrouteservice: OpenRouteService API (requires ROUTING_API_KEY)
    |
    | Provider selection:
    |   ROUTING_BASE_URL=https://api.openrouteservice.org/v2
    |   ROUTING_PROVIDER=openrouteservice
    |   ROUTING_API_KEY=<your-ors-api-key>  (store in secret manager, not .env.example)
    */
    'routing_base_url' => env('ROUTING_BASE_URL'),
    'routing_provider' => env('ROUTING_PROVIDER', 'osrm'),
    'routing_api_key'  => env('ROUTING_API_KEY'),

    'vendor_session_minutes' => (int) env('VENDOR_SESSION_MINUTES', 120),

    /* Private tour originals are deleted after this many days. Sanitized public derivatives remain. */
    'tour_original_retention_days' => (int) env('TOUR_ORIGINAL_RETENTION_DAYS', 30),
];
