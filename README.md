# LocalSpot

LocalSpot helps customers find products at participating physical stores near a selected location. It supports discovery, store information, advertising and in-app navigation. It does not provide online ordering, checkout or delivery.

The development plan in [LocalSpot_App_Development_Plan.md](LocalSpot_App_Development_Plan.md) is the source of truth for product scope, architecture and implementation priorities.

## Architecture

- Flutter is the mobile app and handles the UI, Firebase sign-in, device location, camera, map and panorama viewer.
- Firebase Authentication provides account identity. Flutter sends Firebase ID tokens to the Laravel API.
- Laravel in `backend/` is the trusted API and enforces roles, ownership and business rules.
- Cloud Firestore is the primary application-record database. Laravel accesses it with server credentials; Flutter business-data reads and writes go through Laravel.
- Cloud Storage holds private quarantine uploads and approved media derivatives. Flutter uploads only to UID-scoped quarantine paths after requesting an upload intent from Laravel.
- A dedicated search service, actual image recognition and panorama privacy processing are planned work and are not yet complete.

Production app flows use `LocalSpotGateway` and `LaravelApiClient`; Firebase Auth remains the identity provider.

## Repository layout

- `lib/` — Flutter app
- `backend/` — Laravel API and Firestore integration
- `firestore.rules`, `firestore.indexes.json`, `storage.rules`, `firebase.json` — Firebase configuration
- `docs/OPERATIONS.md` — environment and deployment operations

## Local development

1. Install Flutter, Dart, PHP 8.2+, Composer, Node.js and Firebase CLI.
2. Configure Firebase Authentication (Email/Password), Firestore and Cloud Storage for a development project. Use the Firebase Emulator Suite where practical.
3. Configure FlutterFire for the Android app and keep generated client configuration limited to public Firebase app settings; never add service-account credentials to Flutter.
4. Configure `backend/.env` with `FIREBASE_PROJECT_ID`, `FIREBASE_STORAGE_BUCKET`, `GOOGLE_APPLICATION_CREDENTIALS` (or local Application Default Credentials), and `LARAVEL_API_URL` as appropriate. Service credentials belong only in the backend environment.
5. Install app dependencies with `flutter pub get`; start Laravel from `backend/` with `php artisan serve` or the documented Docker Compose setup.
6. Run Flutter with the API base URL set for the device/emulator, for example `--dart-define=LARAVEL_API_URL=http://10.0.2.2:8000/api/v1` for an Android emulator.

### Run on a USB-connected Android phone (Windows)

Connect the phone, enable USB debugging, and accept its authorization prompt. From the repository root, run:

```powershell
.\run_localspot.ps1
```

The script resolves Flutter, PHP and ADB; selects the connected phone (or prompts if there are several); configures ADB reverse; verifies Laravel can read Firestore; then runs Flutter with the phone's API URL. To select a phone explicitly, pass `-DeviceId <adb-serial>`. The script stops only the Laravel process it started when Flutter exits. It reuses a healthy LocalSpot API already listening on port 8000.

For Firebase setup, emulator ports, Docker and production configuration, follow the development plan and [operations guide](docs/OPERATIONS.md). Demo fixtures are for development only; they are not migrated production data.

## Verification commands

```bash
flutter analyze
flutter test
cd backend && php artisan test
```

These commands are available for local verification. Passing tests alone do not establish production readiness; the plan's security, migration, media, search and operations acceptance items also apply.

## Production boundary

Use HTTPS for the API, least-privilege Google credentials for Laravel, deny direct client access to Firestore business collections, and keep raw uploads private. Do not expose service-account keys in source code, the Flutter app or container images. Third-party Street View imagery, online ordering and delivery are outside this release.
