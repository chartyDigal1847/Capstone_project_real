# Locentra API Worker (migration workspace)

This is a separate, local-only Worker project for the Cloudflare backend migration. It does not replace or change the existing `locentra-upload-gateway` Worker. Its Wrangler configuration uses the Firebase Auth emulator, Firestore emulator, and Wrangler's local R2 simulator under the `demo-localspot` project.

## Local setup

Start the Auth and Firestore emulators from the repository root:

```powershell
firebase emulators:start --project demo-localspot --only auth,firestore
```

In a second terminal:

```powershell
npm install
npm run typecheck
npm test
npm run dev
```

Wrangler local development provides the `MEDIA_BUCKET` simulator. It is not configured for a remote bucket. The API Worker listens on port 8788 by default, leaving 8787 for the upload gateway. Add `-- --ip 0.0.0.0` to `npm run dev` when Android devices need LAN access, as described in `docs/OPERATIONS.md`. Its Auth emulator token verification is enabled only by `LOCAL_EMULATORS=true` and the `demo-localspot` project check. Emulator mode also rejects public request hosts; only localhost and private-LAN hosts can reach it, so the checked-in local config cannot serve API traffic through `workers.dev`. Production App Check and Firebase ID token verification use the official Firebase signing-key endpoints.

## Production credential boundary

`FIREBASE_SERVICE_ACCOUNT_JSON` is an environment secret input and must never be stored in Git, Wrangler vars, Flutter, or test fixtures. Production REST calls use the `https://www.googleapis.com/auth/datastore` OAuth scope and the service account's `roles/datastore.user` grant. The application must still enforce roles, ownership, validation, and every other access rule because this credential bypasses Firestore Rules.

No production endpoint, service-account secret, Cloudflare deployment, or Firebase resource is configured here. Production use remains blocked until the Spark/no-billing IAM path is verified and the user approves production resource changes.

## Migration status

Implemented foundation: Firebase ID token signature/issuer/audience/expiry checks, custom-backend App Check JWT verification, emulator Auth verification, Firestore REST OAuth, transaction, paginated inventory and aggregate-count primitives, and idempotent customer-profile bootstrap. Implemented routes currently cover profile bootstrap and account deletion, feedback/report intake and report resolution, vendor locations, promotions, listings, store applications/review/membership, draft tour creation and viewpoint management, tour publication and public panorama capability issuance, product/store/panorama-original media reservation and finalization, immutable panorama derivative reservation/finalization and owner review attestation, private media access, deletion and abandoned-reservation cleanup, and admin storage quota/reconciliation/orphan deletion. Cloudflare Cron runs expired unlinked-media cleanup every 15 minutes in resumable batches (at most five candidate records and two R2 objects per invocation). Full R2 reconciliation remains available on demand to an administrator; it is not scheduled because its whole-inventory scan has not been shown to fit the Free plan's per-invocation CPU limit.

The panorama image processor remains on-device. Face blur is optional: the selected original can be uploaded directly, while choosing blur runs the existing processing and owner-review flow. For direct original uploads, the Worker records the owner's selection when it verifies and finalizes the derivative; no separate privacy-review screen or confirmation is required. The Worker still verifies authenticated ownership, image bytes and hash, quota, and publication state. Public tours may contain identifiable people when blur is skipped. Flutter can opt into the migrated callable routes, media reservation/finalization, profile bootstrap, and account deletion by setting `LOCALSPOT_BACKEND_URL`; otherwise its current Firebase callable flow remains in effect. The Firebase Auth user-created trigger still exists and is not removed. Production must set `FIREBASE_WEB_API_KEY` and `FIREBASE_ANDROID_APP_ID` as Worker variables for per-request account status/revocation and App Check identity verification. Authenticated private access to an owner's original or verified derivative and public access to published tours are implemented. On-demand admin reconciliation is available at `/api/v1/admin/storage/reconcile` and uses the same gateway URL and signing secret listed below. The Worker returns `501` only for unmatched API routes and for storage-administration actions that have not been migrated into the storage reconciliation port. The endpoint inventory in `docs/CLOUDFLARE_FUNCTIONS_MIGRATION.md` is the route coverage reference. Production readiness is separate from the isolated trial Worker.

The media reservation, finalization, private access, and deletion routes are `/api/v1/media/reservations`, `/api/v1/media/finalize`, `/api/v1/media/private-access`, and `/api/v1/media/delete`. Panorama derivative reservation and finalization use `/api/v1/media/panorama-derivative/reservations` and `/api/v1/media/panorama-derivative/finalize`; owner review attestation, private access, publication, and public access use `/api/v1/tours/panorama/review`, `/api/v1/tours/panorama/private-access`, `/api/v1/tours/panorama/publish`, and `/api/v1/tours/panorama/published-access`. Admin cleanup for abandoned reservations is `/api/v1/admin/media/cleanup-reservations`. Orphan deletion is `/api/v1/admin/storage/orphans/delete`, and on-demand reconciliation is `/api/v1/admin/storage/reconcile`; these R2 routes require the existing gateway's ES256 private JWK in the `R2_GATEWAY_PRIVATE_JWK` Worker secret and its HTTPS base URL in `R2_GATEWAY_URL`. Neither value is configured here. The worker verifies upload eligibility and quota, signs gateway-compatible capabilities, strips image metadata, updates the storage ledger, honors the maintenance lock, and confirms object mutations. Do not point these settings at production as part of local validation.
