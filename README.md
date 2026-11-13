# LocalSpot

Philippine local store and product locator. Vendors publish listings; customers search nearby participating stores and navigate there. There is no cart, checkout, or delivery.

**Pilot area:** Cubao, Quezon City.

## Architecture

LocalSpot is a Flutter app backed by Firebase Authentication, Cloud Firestore, Cloud Storage, and 2nd generation Cloud Functions. Firestore and Storage Security Rules protect client operations; privileged workflows run through authenticated callable Functions. No separate application server or database is required.

## Repository layout

- Flutter application: `lib/`
- Firebase configuration, rules, and indexes: repository root
- Cloud Functions (TypeScript): `functions/`
- Emulator and maintenance scripts: `scripts/`
- Operational and release guidance: `docs/`

## Local development

Install Flutter, Node.js 22, Java, and the Firebase CLI. Configure a Firebase project with `flutterfire configure`, enable the required Firebase products, and review [Firebase operations](docs/OPERATIONS.md) before deploying configuration.

```bash
flutter pub get
flutter run
```

For local Firebase development, start the Local Emulator Suite using the repository's `firebase.json` configuration. Keep emulator data and development credentials out of production projects.

## Checks

```bash
flutter analyze
flutter test
npm --prefix functions run build
```

The CI workflow also runs Firebase Emulator Suite smoke checks. See [the repository audit](docs/FIREBASE_REPOSITORY_AUDIT.md) for current verification limits and outstanding production setup.

## Production

Production release signing and Firebase project identity must be configured explicitly. See [Android release signing](docs/ANDROID_RELEASE_SIGNING.md) and [Firebase operations](docs/OPERATIONS.md). Never place service-account credentials in the Flutter app.
