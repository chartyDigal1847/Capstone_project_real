<?php

return [
    /*
    | Optional OSRM-compatible routing base, for example https://router.example/osrm.
    | Leave empty to return a local straight-line preview (used in tests and offline).
    | Do not point production at the public project-osrm.org demo server.
    */
    'routing_base_url' => env('ROUTING_BASE_URL'),

    'vendor_session_minutes' => (int) env('VENDOR_SESSION_MINUTES', 120),

    /* Private tour originals are deleted after this many days. Sanitized public derivatives remain. */
    'tour_original_retention_days' => (int) env('TOUR_ORIGINAL_RETENTION_DAYS', 30),
];
