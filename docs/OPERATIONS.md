# LocalSpot operations

This guide follows the target architecture in [LocalSpot_App_Development_Plan.md](../LocalSpot_App_Development_Plan.md): Firebase Authentication, Laravel as the trusted API, Firestore as the primary record store, and Cloud Storage for media. Production setup is not complete until the plan's security and recovery acceptance items have been verified.

## Environments and credentials

- Keep separate Firebase projects and credentials for development, staging and production.
- Configure Laravel with `FIREBASE_PROJECT_ID`, `FIREBASE_STORAGE_BUCKET`, and Google Application Default Credentials or a secret-managed service identity.
- Grant the backend identity only the Firestore and Storage permissions it needs. Never commit service-account keys or put them in Flutter configuration or container images.
- Configure `LARAVEL_API_URL` per environment. Production traffic must use HTTPS.
- Emulator and test-token bypasses must remain limited to local/test environments and must not be enabled in production.

## Security boundary

- Flutter authenticates with Firebase Auth and sends refreshed Firebase ID tokens to Laravel.
- Laravel verifies token signature and claims, resolves server-managed roles and memberships, and enforces ownership on every protected operation.
- Flutter must not read or write Firestore business collections directly. Firestore Rules should deny those client operations; Laravel's server credentials use IAM.
- Flutter media uploads must use Laravel-issued intents and UID-scoped quarantine paths. Raw originals stay private; only approved derivatives may be delivered publicly.
- Restrict map/routing keys to their intended apps and domains. Do not place AI, Firestore or Storage service credentials in the client.

## Local development

1. Start Firebase Auth, Firestore and Storage emulators using the repository's `firebase.json` when working locally.
2. Configure the Laravel backend to use the intended Firebase project or emulator endpoints and set its API base URL.
3. Run Flutter with an API URL reachable from the chosen device. Android Emulator typically reaches the host at `10.0.2.2`.
4. Use seeded accounts and catalog records only for development. Do not treat demo records as migrated or production data.

## Release and deployment

1. Build and deploy the Laravel container through a staging environment first.
2. Verify `GET /api/v1/health`, Firebase token verification, catalog/search, an authorized owner operation and a denied unauthorized operation.
3. Verify Firestore Rules and Storage Rules with emulator tests before deployment.
4. Verify quarantine upload authorization, server-side object verification, processing status and that raw originals cannot be read publicly.
5. Confirm Firestore indexes, scheduled backups/exports, billing alerts, logs, health checks and rollback steps before production.
6. Deploy a reviewed immutable image tag over HTTPS; keep secrets in the runtime secret store.

## Backups and recovery

Firestore exports and Cloud Storage objects both need recovery procedures. Configure scheduled Firestore exports to a protected bucket, define retention, and test restoring into a separate environment. Back up required Storage objects and metadata as well. A backup is not proven until a restore has been completed and checked outside production.

Record the release image, Firestore export, Storage recovery point and rollback steps for each production release. Do not use MySQL migrations or a MySQL volume as the production recovery plan for the target architecture.

## Monitoring and background work

- Monitor API health, Firebase token failures, Firestore/Storage errors, search latency, queue failures and billing.
- Do not log bearer tokens, passwords, raw uploaded media or other unnecessary personal data.
- Configure queue workers and retry/failed-job handling for recognition, media processing, tour privacy processing and search-index synchronization before enabling those capabilities.
- Panorama publication must remain blocked until real server-side privacy processing and owner review succeed. The current placeholder processing job is not an ML privacy pipeline.

## Out of scope

Do not enable third-party Street View or street-level imagery, online ordering, checkout, delivery or rider tracking for this release.
