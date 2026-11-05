# LocalSpot Laravel API

Laravel is the trusted application API for LocalSpot. It verifies Firebase Authentication ID tokens, enforces authorization, and reads/writes application records in Cloud Firestore. Flutter must not use direct Firestore business-data access in app flows.

## Configure

Install dependencies with Composer, then configure the backend environment with:

- `FIREBASE_PROJECT_ID`
- `FIREBASE_STORAGE_BUCKET`
- Google Application Default Credentials or a secret-managed service identity via `GOOGLE_APPLICATION_CREDENTIALS`
- Emulator host settings only for local development

Never commit service-account keys. Consult the root [development plan](../LocalSpot_App_Development_Plan.md) and [operations guide](../docs/OPERATIONS.md) for the target architecture and environment requirements.

## Run locally

```bash
php artisan serve
```

The versioned API is available under `/api/v1`. For development, Firebase Auth, Firestore and Storage emulators are configured in the repository's `firebase.json`.

## Current implementation limits

The API includes Firebase token verification and Firestore-backed routes. Some planned capabilities are still incomplete: Cloud Storage object verification and media processing, actual product vision/OCR, geohash-bounded nearby queries, dedicated semantic/vector search, real panorama person/face processing, and production operations. Do not treat the existing placeholder jobs as completed media privacy processing.

This backend is not the old MySQL/Sanctum application. MySQL is not the target production record store and Sanctum is not the target mobile identity system.
