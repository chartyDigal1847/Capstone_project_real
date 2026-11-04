# LocalSpot

Philippine local store and product locator. Vendors publish listings; customers search nearby participating stores and navigate there. There is no cart, checkout, or delivery.

**Pilot area:** Cubao, Quezon City.

**Backend:** Firebase Authentication, Cloud Firestore, and Cloud Storage. The Flutter app talks to Firebase with Security Rules; it does not embed database credentials. The Laravel API in `backend/` is kept as a legacy fallback until Firebase is fully configured.

## Layout

- Flutter app at the repository root (`lib/`)
- Firebase rules and indexes at the repository root (`firebase.json`, `firestore.rules`, `storage.rules`)
- Legacy Laravel API in `backend/` (optional)

## Local development

1. Install Flutter and Node.js 20+.
2. Sign in to Firebase: `npx -y firebase-tools@latest login`
3. Create or select a Firebase project, then run `flutterfire configure` (or fill `lib/firebase_options.dart` and set `configured` to `true`).
4. Enable Email/Password auth, create Firestore in `asia-southeast1`, and deploy rules:
   `npx -y firebase-tools@latest deploy --only auth,firestore,storage`
5. From the repo root: `flutter pub get` then `flutter run`.

Until Firebase options are filled in, the app uses on-device demo data (password `demo1234`).

Official setup references:
- Add Firebase to Flutter: https://firebase.google.com/docs/flutter/setup
- FlutterFire Auth: https://firebase.google.com/docs/auth/flutter/start
- Cloud Firestore Flutter: https://firebase.google.com/docs/firestore/quickstart

## Tests

```bash
flutter analyze && flutter test
```

Legacy API tests remain at `cd backend && php artisan test`.

## Production

Deploy Firestore/Storage/Auth rules with the Firebase CLI. Keep client config in `lib/firebase_options.dart` / `android/app/google-services.json`. Do not put service-account keys in the app. See [docs/OPERATIONS.md](docs/OPERATIONS.md).
