# LocalSpot

Philippine local store and product locator. Vendors publish listings; customers search nearby participating stores and navigate there. There is no cart, checkout, or delivery.

**Pilot area:** Cubao, Quezon City.

## Layout

- Flutter app at the repository root (`lib/`)
- Laravel API in `backend/` (Laravel Sail / Docker for MySQL)

The mobile app talks only to `/api/v1`. Database credentials stay on the server.

## Local development

1. Start Docker Desktop.
2. From `backend/`: copy `.env.example` to `.env`, then `./vendor/bin/sail up -d`, `sail artisan migrate --seed`.
3. API: `http://127.0.0.1:8000/api/v1` (Android emulator: `http://10.0.2.2:8000/api/v1`).
4. From the repo root: `flutter pub get`, then run on Android with your **public** Mapbox token:
   `flutter run --dart-define=ACCESS_TOKEN=pk.REPLACE_WITH_PUBLIC_TOKEN`
5. Demo password for seeded accounts: `demo`.

The app renders Mapbox Streets and requests driving routes from the Mapbox Directions API.
Create a public token (`pk.`) with the read scopes required for Maps and Directions, and keep it out of source control.
Never use a secret token (`sk.`) in the mobile app. The SDK's Mapbox logo and clickable attribution
remain visible, including the telemetry opt-out. Check [Mapbox pricing and terms](https://www.mapbox.com/pricing/)
before production use: the Flutter Maps SDK is measured in monthly active users, while Directions is
measured in API requests. Free-tier amounts, prices, and rate limits depend on the current plan; see the
[Maps SDK pricing guide](https://docs.mapbox.com/flutter/maps/guides/pricing/) and
[Directions API pricing and limits](https://docs.mapbox.com/api/navigation/directions/).

Customer GPS is requested only while using the app. Store/provider coordinates come from the existing
Laravel catalog; Firebase is not configured in this project. With no Mapbox token, the app shows a
configuration notice and does not draw a fake road route.

Health check: `GET /api/v1/health` and `GET /up`.

## Tests

```bash
cd backend && php artisan test
flutter analyze && flutter test
```

CI runs both suites and builds the production API image.

## Production

Use `backend/docker/production/Dockerfile` and `backend/compose.production.yaml`. Put secrets in the host environment, not in git. Terminate HTTPS at a reverse proxy. Do not publish MySQL. See [docs/OPERATIONS.md](docs/OPERATIONS.md) for backup, restore, release, and rollback.
