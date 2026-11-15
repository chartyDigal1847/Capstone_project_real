# Firebase operations

This runbook covers LocalSpot's Firebase and Flutter deployment. No application server or self-hosted database is part of the runtime architecture.

## Local development

1. Install Flutter, Node.js 22, Java, and Firebase CLI.
2. Install app and Functions dependencies with `flutter pub get` and `npm --prefix functions ci`.
3. Start the configured local services with `firebase emulators:start --project demo-localspot`.
4. Run a debug app against emulators only with `flutter run --dart-define=USE_FIREBASE_EMULATORS=true --dart-define=FIREBASE_EMULATOR_PROJECT_ID=demo-localspot --dart-define=FIREBASE_EMULATOR_HOST=<host-address>`. Android Emulator typically uses `10.0.2.2`; a physical device must use the development computer's reachable private LAN address. Debug builds fail closed without these emulator settings and verify the `demo-localspot` project.
5. Run Flutter analysis/tests and the emulator smoke scripts listed in `scripts/package.json` and the GitHub Actions workflow.
6. Keep emulator data, debug App Check tokens, and service credentials out of production. Release builds reject emulator configuration and verify the project's configured production Firebase ID.

## Catalog image cleanup

`scripts/remove_unsplash_catalog_images.cjs` clears only `images.unsplash.com` and `source.unsplash.com` values from product/store image fields and tour node images. It does not delete uploaded Storage objects or change other URLs. First run a dry run with `node scripts/remove_unsplash_catalog_images.cjs --project=<project-id>` and review the per-collection counts. To apply, add `--apply --confirm-project=<same-project-id>`. Run against a confirmed staging or production target only after reviewing the counts; blank images use the app's neutral placeholder until an owner uploads a replacement.

## Project configuration and release

- Use distinct Firebase projects for development, staging, and production; the repository's checked-in Firebase configuration is not proof that production is configured.
- Review `firestore.rules`, `firestore.indexes.json`, the Cloudflare Worker configuration, and every Functions change before deployment. LocalSpot uses Cloudflare R2 for media; Firebase Storage is not configured or part of the runtime architecture. The retained legacy `storage.rules` file is unused and must not be deployed.
- Deploy only the required Firebase resources with the Firebase CLI and an explicitly selected project. Never deploy against a project ID copied from a local development build without confirming the target.
- Configure Firebase App Check for the registered Android application, monitor metrics, and enable enforcement for supported products after validating legitimate traffic.
- Configure Android package identity, production Firebase app registration, upload signing, Play Integrity, and release build properties using `docs/ANDROID_RELEASE_SIGNING.md`.
- Do not put service-account keys, API secrets, or signing keys in Flutter assets or source control. Store server secrets in Firebase Functions secret configuration.

## Monitoring and recovery

- Configure billing budgets and alerts, Firestore/Functions quotas, Functions max instances, and AI usage controls in the Firebase project. Budget alerts are not hard spending limits.
- Review Cloud Functions logs, Crashlytics reports, Analytics privacy settings, and Firebase App Check metrics after each release. Avoid logging account identifiers, precise location, search terms, or uploaded media paths.
- Define Firestore export and private R2 backup/retention schedules for the recovery objective. Perform a restore drill in a separate project before relying on backups. Do not create or enable Firebase Storage for this purpose.
- For an incident, disable the affected callable or product through Firebase configuration, preserve relevant logs, and deploy a reviewed rollback. Validate the recovery in staging before restoring normal traffic.

## Production readiness gaps

The repository audit records unresolved work, including production project separation, Firebase Console setup, release identity/signing, backup restore verification, and emulator/CI checks that have not yet passed in this environment. Treat these as release gates; the presence of configuration files alone does not complete them.
