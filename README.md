# Locentra

Philippine local store and product locator. Vendors publish listings; customers search nearby stores and navigate there. There is no cart, checkout, or delivery.

**Pilot area:** Cubao, Quezon City.

## Project layout

- Flutter Android application: `lib/`
- Firebase Authentication, Cloud Firestore rules, and indexes: repository root
- Retained Firebase Functions source for migration comparison and rollback: `functions/`
- Local Cloudflare API Worker: `cloudflare/backend-worker/`
- Separate upload and media gateway Worker: `cloudflare/worker/`
- Migration, security, and free-tier planning: `docs/`

The target backend keeps Firebase Authentication and Firestore on Spark and moves trusted operations to Cloudflare Workers and R2. The Firebase Functions source remains in the repository; do not deploy it as part of local migration validation. No production Worker, R2 bucket, or Spark service-account credentials are configured by these local instructions.

## Local development

1. Install Flutter, Node.js 22 or newer, Java, and Firebase CLI. Run `flutter pub get`.
2. Start only the Auth and Firestore emulators with `firebase emulators:start --project demo-localspot --only auth,firestore`.
3. For API and media validation, follow the two-Worker commands in [docs/OPERATIONS.md](docs/OPERATIONS.md). The API Worker uses local emulators and R2 simulation; no production bucket is configured. For API-only development, install dependencies in `cloudflare/backend-worker` and run `npm run dev` there.
4. Run the Android app with the emulator settings from [docs/OPERATIONS.md](docs/OPERATIONS.md). To render Mapbox Streets and Directions locally, supply the ignored `config/local.json` file with `--dart-define-from-file=config/local.json`.
5. Run Flutter checks with `flutter analyze` and `flutter test`. Worker checks are `npm run typecheck` and `npm test` from `cloudflare/backend-worker`.

For physical-device or media-gateway setup, environment-specific ports, and emulator host addresses, follow [docs/OPERATIONS.md](docs/OPERATIONS.md). Never use emulator settings or local R2 simulation in a release build.

### Docker toolchain

Docker Desktop with Docker Compose is the easiest way to share a consistent
build environment. The image pins Flutter 3.47.1 / Dart 3.13.1, Node.js
24.14.1 / npm 11.11.0, Java 17, Android platform 36, Build Tools 36.0.0,
NDK 28.2.13676358, and CMake 3.22.1. Gradle, Flutter packages, and Worker
packages use the versions pinned in their checked-in wrapper and lock files.

From PowerShell at the repository root, build the image and start a project
shell:

```powershell
docker compose build
docker compose run --rm locentra-dev
```

Inside the container, install dependencies from the lock files:

```bash
flutter pub get
npm --prefix cloudflare/backend-worker ci
npm --prefix cloudflare/worker ci
```

To build the signed trial APK, first keep your ignored `config/local.json`,
`android/key.properties`, and release keystore in place on the host. Then run
the same guarded trial build used by this repository:

```bash
flutter build apk --flavor trial --release --target-platform android-arm64 \
  --dart-define=LOCALSPOT_TRIAL_RELEASE=true \
  --dart-define=LOCALSPOT_BACKEND_URL="$LOCALSPOT_BACKEND_URL" \
  --dart-define-from-file=config/local.json \
  --android-project-arg=localspotReleaseEnvironment=trial \
  --android-project-arg=localspotReleaseProjectId=locentra-spark-trial-20261117 \
  --android-project-arg=localspotReleaseApplicationId=app.locentra.mobile
```

The repository is mounted into the container, so APKs appear under the host
project’s `build/` directory. Docker stores Gradle, Pub, npm, and Linux
`node_modules` caches in named volumes. Local Mapbox configuration, signing
keys, secrets, dependencies, and build outputs are excluded from the Docker
image. The Docker files are not Flutter assets and are never bundled into the
APK. See [docs/DOCKER_DEVELOPMENT.md](docs/DOCKER_DEVELOPMENT.md) for details.

## Mapbox configuration

The restricted public token is stored in the ignored `config/local.json` file under `PUBLIC_MAPBOX_ACCESS_TOKEN`. Flutter receives it at launch/build time with `--dart-define-from-file=config/local.json`. Do not put the token in Dart source or commit the local config file. Never use a private `sk.` token or a service-account credential in the mobile app.

The app renders Mapbox Streets and requests driving routes from the Mapbox Directions API. Create a public token (`pk.`) with the read scopes required for Maps and Directions. Restrict it by platform, package name, allowed URLs, and usage limits in the Mapbox dashboard. The SDK's Mapbox logo and clickable attribution remain visible, including the telemetry opt-out. Check [Mapbox pricing and terms](https://www.mapbox.com/pricing/) before production use: the Flutter Maps SDK is measured in monthly active users, while Directions is measured in API requests. Free-tier amounts, prices, and rate limits depend on the current plan; see the [Maps SDK pricing guide](https://docs.mapbox.com/flutter/maps/guides/pricing/) and [Directions API pricing and limits](https://docs.mapbox.com/api/navigation/directions/).

Customer GPS is requested only while using the app. Store/provider coordinates come from Firestore. With no Mapbox token, the app shows a configuration notice and does not draw a fake road route.

## Migration and release

Read [docs/CLOUDFLARE_BACKEND_MIGRATION.md](docs/CLOUDFLARE_BACKEND_MIGRATION.md) for current migration state, [docs/CLOUDFLARE_FUNCTIONS_MIGRATION.md](docs/CLOUDFLARE_FUNCTIONS_MIGRATION.md) for the Function-to-Worker inventory, and [docs/LOCALSPOT_FREE_TRIAL_DEPLOYMENT.md](docs/LOCALSPOT_FREE_TRIAL_DEPLOYMENT.md) for the gated trial plan. Production setup and deployment require separate review and approval. Do not activate Firebase Blaze, link billing, deploy Functions, or point local Workers at existing production resources as part of local development.
