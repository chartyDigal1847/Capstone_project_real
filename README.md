# LocalSpot

Philippine local store and product locator. Vendors publish listings; customers search nearby participating stores and navigate there. There is no cart, checkout, or delivery.

**Pilot area:** Cubao, Quezon City.

## Layout

- Flutter app at the repository root (`lib/`)
- Firebase Authentication, Firestore, Storage, and Cloud Functions
- Firebase rules and indexes at the repository root

## Local development

1. Install Flutter and Firebase CLI, then run `flutter pub get`.
2. Select the Firebase project with `firebase use capstone-project-561a2`.
3. Run the Firebase emulators for local development, or deploy the rules and
   functions for a shared environment.
4. Run the app with a restricted **public** Mapbox token:
   `flutter run --dart-define=PUBLIC_MAPBOX_ACCESS_TOKEN=pk.REPLACE_WITH_PUBLIC_TOKEN`

For repeatable builds, copy `config/public.json.example` to
`config/local.json`, replace the placeholder with your own restricted `pk.`
token, and run the **Flutter with Mapbox** configuration in
`.vscode/launch.json`. You can also run:
`flutter run --dart-define-from-file=config/local.json`.

`config/local.json` stays ignored because GitHub secret scanning may classify
Mapbox tokens as credentials, even when they are public `pk.` client tokens.
Never put a private `sk.` token or service-account credential in the repository.

The app renders Mapbox Streets and requests driving routes from the Mapbox Directions API.
Create a public token (`pk.`) with the read scopes required for Maps and Directions. Restrict it
by platform, bundle ID/package name, allowed URLs, and usage limits in the Mapbox dashboard.
Never use a secret token (`sk.`) in the mobile app. The SDK's Mapbox logo and clickable attribution
remain visible, including the telemetry opt-out. Check [Mapbox pricing and terms](https://www.mapbox.com/pricing/)
before production use: the Flutter Maps SDK is measured in monthly active users, while Directions is
measured in API requests. Free-tier amounts, prices, and rate limits depend on the current plan; see the
[Maps SDK pricing guide](https://docs.mapbox.com/flutter/maps/guides/pricing/) and
[Directions API pricing and limits](https://docs.mapbox.com/api/navigation/directions/).

Customer GPS is requested only while using the app. Store/provider coordinates come from Firestore.
With no Mapbox token, the app shows a configuration notice and does not draw a fake road route.

## Tests

```bash
cd backend && php artisan test
flutter analyze && flutter test
```

CI runs both suites and builds the production API image.

## Production

Deploy Cloud Functions and Firebase rules with the Firebase CLI. Keep service-account
credentials and server secrets outside the repository. Firebase web/mobile API keys may
be public client configuration, but access must be enforced by Authentication, App Check,
Firestore/Storage rules, and callable-function authorization. See [docs/OPERATIONS.md](docs/OPERATIONS.md)
for release and rollback guidance.
