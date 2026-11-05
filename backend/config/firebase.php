<?php

return [

    /*
    |--------------------------------------------------------------------------
    | Firebase Project Configuration
    |--------------------------------------------------------------------------
    | Firebase Authentication is the sole identity provider. Laravel verifies
    | Firebase ID tokens using the documented JWT procedure (RS256 against
    | Google's public keys). Cloud Firestore is the only primary application
    | database. The current adapter uses Firestore REST and Google's Auth
    | library, with local credential files and ADC/IAM support.
    | Cloud Storage holds media; Laravel authorizes upload intents and
    | controls publication of sanitized derivatives.
    */

    'project_id' => env('FIREBASE_PROJECT_ID'),

    // Firestore configuration — used by the Firestore REST API adapter.
    'firestore' => [
        'project_id' => env('FIREBASE_PROJECT_ID'),
        'emulator_host' => env('FIRESTORE_EMULATOR_HOST'),
        'credentials' => env('GOOGLE_APPLICATION_CREDENTIALS'),
    ],

    // Firebase Auth token verification — RS256 JWT against Google's public keys.
    'auth' => [
        'project_id' => env('FIREBASE_PROJECT_ID'),
        // Token issuer pattern: https://securetoken.google.com/<projectId>
        'issuer' => 'https://securetoken.google.com/' . env('FIREBASE_PROJECT_ID'),
        // Audience must equal the Firebase project ID.
        'audience' => env('FIREBASE_PROJECT_ID'),
        // Google's public key source for RS256 verification.
        'public_key_url' => 'https://www.googleapis.com/robot/v1/metadata/x509/securetoken@system.gserviceaccount.com',
        // Cache TTL for public keys (seconds). Respects cache-control headers.
        'key_cache_ttl' => 3600,
        // Allow emulator/test-token bypass in local/test only.
        'emulator_host' => env('FIREBASE_AUTH_EMULATOR_HOST') ?: null,
        'allow_emulator' => filled(env('FIREBASE_AUTH_EMULATOR_HOST')),
    ],

    // Cloud Storage configuration — used for media upload intents and
    // short-lived signed download URLs for approved derivatives.
    'storage' => [
        'project_id' => env('FIREBASE_PROJECT_ID'),
        'bucket' => env('FIREBASE_STORAGE_BUCKET', env('FIREBASE_PROJECT_ID') . '.appspot.com'),
        'emulator_host' => env('FIREBASE_STORAGE_EMULATOR_HOST'),
        'credentials' => env('GOOGLE_APPLICATION_CREDENTIALS'),
    ],

];
