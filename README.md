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
4. From the repo root: `flutter pub get` then `flutter run`.
5. Demo password for seeded accounts: `demo`.

Health check: `GET /api/v1/health` and `GET /up`.

## Tests

```bash
cd backend && php artisan test
flutter analyze && flutter test
```

CI runs both suites and builds the production API image.

## Production

Use `backend/docker/production/Dockerfile` and `backend/compose.production.yaml`. Put secrets in the host environment, not in git. Terminate HTTPS at a reverse proxy. Do not publish MySQL. See [docs/OPERATIONS.md](docs/OPERATIONS.md) for backup, restore, release, and rollback.
