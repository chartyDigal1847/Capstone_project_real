# LocalSpot operations

Pilot operations for a single-server Docker Compose deployment. Kubernetes is not required.

## Secrets and configuration

- Keep `.env` and production secrets out of git and out of the image (see `backend/.dockerignore`).
- Set `APP_ENV=production`, `APP_DEBUG=false`, a unique `APP_KEY`, and database passwords on the host.
- Sanctum tokens expire (`SANCTUM_TOKEN_EXPIRATION_MINUTES`) and logout revokes the current token.
- Restrict public map-tile and routing keys by app and domain. Do not put MySQL or AI credentials in Flutter.
- Third-party Street View and street-level imagery are out of scope; do not enable Google Street View, Mapillary, KartaView, or Panoramax for this release.

## HTTPS and network

- Publish only the reverse proxy (443). The Compose file keeps MySQL on the private `internal` network.
- Terminate TLS at Caddy, nginx, or a managed load balancer in front of `app:8080`.
- Do not expose port 3306 on the public internet.

## Images and releases

1. CI must pass (`php artisan test`, `flutter analyze`, `flutter test`).
2. CI builds `backend/docker/production/Dockerfile` and tags it with the git SHA. Do not deploy Sail or `latest` as the only identifier.
3. Deploy that tag to staging, run `GET /api/v1/health`, then a login + product search smoke test.
4. Back up production data. Run `php artisan migrate --force` as a controlled step, not from every replica on boot.
5. Point Compose `LOCALSPOT_IMAGE` at the approved tag and recreate the `app` service.

Rollback: keep the previous image tag. Restore the matching backup if a migration cannot be reversed safely. Re-point `LOCALSPOT_IMAGE` and recreate `app`.

## Backups

Daily at 02:15 the app schedules `php artisan localspot:backup`, which writes JSON snapshots under `storage/app/backups`.

For MySQL volume backups on the host (preferred for restore drills):

```bash
docker compose -f compose.production.yaml exec mysql \
  sh -c 'mysqldump -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE"' > backup-$(date +%Y%m%d).sql
```

Restore drill (use a separate database or staging):

```bash
php artisan localspot:restore storage/app/backups/<file>.json --force
```

A backup is not proven until it has been restored at least once in a non-production environment.

Retain backups according to the pilot recovery objective (suggested: daily copies for 14 days).

## Health, logs, and jobs

- Container health: `GET /up` (Compose healthcheck) and `GET /api/v1/health` (app + database).
- Logs: Docker stdout/stderr; do not log bearer tokens, passwords, or uploaded images.
- Queue workers: add a separate process when async image recognition is enabled. Until then, `QUEUE_CONNECTION=database` with no extra worker is acceptable for the Cubao pilot.
- 360° privacy: originals live on the private disk (`tours/originals/{id}.txt`) and expire after `TOUR_ORIGINAL_RETENTION_DAYS` (default 30). Public viewer URLs are `/storage/tours/{id}/sanitized.jpg`. This is a publication gate, not person-detection ML. Failed processing never publishes the original. Run `php artisan localspot:purge-tour-originals` daily.

## Migrations

Review each migration for compatibility before deploy. Prefer additive changes. Take a backup before destructive schema changes. Do not run `docker compose down -v` on production; that deletes the MySQL volume.
