# Firebase operations

This runbook covers Locentra's Flutter client, Firebase Auth/Firestore, and Cloudflare Worker backend. No self-hosted database is part of the runtime architecture.

Review [FREE_TIER_CAPACITY.md](FREE_TIER_CAPACITY.md) before any production provisioning. The free allowances are account-wide in key places, and R2 overages do not currently have a Cloudflare spend-limit control.

## Local development

1. Install Flutter, Node.js 22, Java, and Firebase CLI.
2. Install app and both Worker dependencies with `flutter pub get`, `npm --prefix cloudflare/backend-worker ci`, and `npm --prefix cloudflare/worker ci`. The legacy Functions source is retained for comparison; do not deploy it as part of the no-Blaze migration.
3. Start only Auth and Firestore with `firebase emulators:start --project demo-localspot --only auth,firestore`; do not start or deploy Functions for this migration workflow. For a physical-device session, use `firebase emulators:start --project demo-localspot --config firebase.physical.local.json --only auth,firestore`, which binds those emulator ports for LAN access.
4. Run the default `local` Android flavor against emulators only with `flutter run --flavor local --dart-define=USE_FIREBASE_EMULATORS=true --dart-define=FIREBASE_EMULATOR_PROJECT_ID=demo-localspot --dart-define=FIREBASE_EMULATOR_HOST=<host-address>`. Android Emulator typically uses `10.0.2.2`; a physical device must use the development computer's reachable private LAN address. Debug builds fail closed without these emulator settings and verify the `demo-localspot` project.
5. Start the upload gateway from `cloudflare/worker` with `npm run dev -- --ip 0.0.0.0` (port 8787); start the API Worker from `cloudflare/backend-worker` with `npm run dev -- --ip 0.0.0.0` (port 8788). Check the ignored `.dev.vars` files so the API Worker points to the local gateway and the running Auth/Firestore emulator addresses. Add `--dart-define=LOCALSPOT_BACKEND_URL=http://10.0.2.2:8788` to the Android Emulator's Flutter command. For a physical device, use the development computer's reachable private LAN address for the Worker URL and Firebase emulator host. Panorama processing remains on-device. Both Wrangler configs use local R2 simulation; do not use `--remote` or a production bucket.
6. Run Flutter analysis/tests and the emulator smoke scripts listed in `scripts/package.json` and the GitHub Actions workflow.
7. Keep emulator data, debug App Check tokens, and service credentials out of production. Release builds reject emulator configuration and verify the project's configured production Firebase ID.

## Catalog image cleanup

`scripts/remove_unsplash_catalog_images.cjs` clears only `images.unsplash.com` and `source.unsplash.com` values from product/store image fields and tour node images. It does not delete uploaded Storage objects or change other URLs. First run a dry run with `node scripts/remove_unsplash_catalog_images.cjs --project=<project-id>` and review the per-collection counts. To apply, add `--apply --confirm-project=<same-project-id>`. Run against a confirmed staging or production target only after reviewing the counts; blank images use the app's neutral placeholder until an owner uploads a replacement.

## Project configuration and release

- Use distinct Firebase projects for development, staging, and production; the repository's checked-in Firebase configuration is not proof that production is configured.
- Review `firestore.rules`, `firestore.indexes.json`, the Cloudflare Worker configuration, and every backend change before an approved deployment. Locentra uses Cloudflare R2 for media; Firebase Storage is not configured or part of the runtime architecture. The retained legacy `storage.rules` file is unused and must not be deployed.
- Do not deploy Firebase Functions for the no-Blaze target. Any approved Firebase resource change must name the isolated trial project and use an explicitly selected project; never deploy against a project ID copied from a local development build without confirming the target.
- Configure Firebase App Check for the registered Android application, monitor metrics, and enable enforcement for supported products after validating legitimate traffic.
- Configure Android package identity, production Firebase app registration, upload signing, Play Integrity, and release build properties using `docs/ANDROID_RELEASE_SIGNING.md`.
- Do not put service-account keys, API secrets, or signing keys in Flutter assets or source control. Store backend secrets in the approved Cloudflare Worker secret store; do not configure Functions secrets for the no-Blaze migration.

## Monitoring and recovery

- Keep Firebase on Spark and monitor Firestore/Auth/App Check quotas. Monitor Worker requests/CPU and whole-account R2 storage/operations; R2 overages do not have a spend cap. Budget alerts are not hard spending limits.
- Review Worker logs, Crashlytics reports, Analytics privacy settings, and Firebase App Check metrics after each release. Avoid logging account identifiers, precise location, search terms, or uploaded media paths.
- Define Firestore export and private R2 backup/retention schedules for the recovery objective. Perform a restore drill in a separate project before relying on backups. Do not create or enable Firebase Storage for this purpose.
- For an incident, disable the affected callable or product through Firebase configuration, preserve relevant logs, and deploy a reviewed rollback. Validate the recovery in staging before restoring normal traffic.

## Production readiness gaps

The repository audit records unresolved work, including production project separation, Firebase Console setup, release identity/signing, backup restore verification, and emulator/CI checks that have not yet passed in this environment. Treat these as release gates; the presence of configuration files alone does not complete them.
