# Locentra R2 upload gateway

This Worker is the only app-facing path to the private `locentrastorage` bucket. Wrangler local development uses its local R2 simulator by default; this configuration intentionally does not enable a remote bucket for `wrangler dev`.

## Local checks

From `cloudflare/worker`:

```powershell
npm install
npm run typecheck
npm test
npm run dev
```

The local health endpoint is `GET http://localhost:8787/healthz`. Protected routes fail closed until `GATEWAY_PUBLIC_JWKS` is configured. Do not put a private signing key in the gateway Worker; it receives only the matching public JWK set. Local emulator testing uses a test-only key in the ignored API Worker `.dev.vars`. An approved migration trial must store the key as a Cloudflare Worker secret. The retained Firebase Functions fallback uses Secret Manager. Never commit private keys or put a production key in Wrangler vars, `.dev.vars`, Flutter, or chat.

## Authorization contract for the trusted backend

User-facing upload and private-media requests carry two independent credentials:

- `Authorization: Bearer <Firebase ID token>`; this Worker verifies the token signature against Firebase's published certificates and checks the project audience, issuer, expiry, and subject.
- `X-Upload-Authorization: Bearer <ES256 JWT>` for uploads, or `X-Gateway-Authorization: Bearer <ES256 JWT>` for private reads. The local migration API Worker or the retained Firebase callable fallback creates this short-lived token only after App Check, ownership, permission, size, rate-limit, and Firestore reservation checks succeed.

Gateway tokens use issuer `localspot-functions`, audience `locentra-upload-gateway`, ES256, a `kid`, `iat`, `exp`, `jti`, and `sub`. Their lifetime is at most five minutes. Upload tokens also include `scope: "upload"`, `objectKey`, `contentType`, `maxBytes`, `mediaType`, `assetId`, and `tourId` for panoramas. Derivative tokens additionally bind `nodeId`, an immutable `revisionId`, and the expected SHA-256 digest. The Worker derives the expected UID-scoped key from signed claims and rejects mismatches. The Flutter app never receives an R2 credential or a token that permits arbitrary object keys.

Private reads use `scope: "media:read"`, `objectKey`, and a `sub` equal to the verified Firebase UID. The migration API Worker, or the retained Firebase Functions fallback, must authorize store-owner/admin access before minting this capability.

Public panorama reads use a separate `scope: "media:public-read"` capability bound to the exact derivative key, tour ID, viewpoint ID, and SHA-256 digest. The migration API Worker, or the retained Firebase Functions fallback, issues it only after checking the published Firestore tour, current owner attestation, verified derivative metadata, finalized quota ledger, and R2 object metadata. The panorama route is not a direct public object URL: guessing a derivative key is insufficient. The Worker additionally requires the object publication marker and matching digest. Responses are `private,no-store`; the short-lived capability is presented in `X-Gateway-Authorization`.

Backend-only tokens use the same issuer, audience, algorithm, and lifetime, but are minted by the local migration API Worker or the retained Firebase Functions fallback and sent as `X-Gateway-Authorization`. Supported scopes are `objects:list`, `object:head`, `object:get`, `object:put`, and `object:delete`. Object-scoped tokens include the exact `objectKey`; writes also include `maxBytes`. Keep the corresponding production private key in the API Worker secret store for the migration path; the legacy Functions fallback keeps its key in Firebase Secret Manager. The public JWKS is configuration, not a secret.

## Routes

| Route | Purpose |
| --- | --- |
| `PUT /v1/uploads/{reservationId}` | Store a reserved product, store, or panorama original in its UID-scoped quarantine path. |
| `GET|HEAD /v1/media/public/{encodedKey}` | Deliver only product/store public-prefix objects with a one-day cache policy. |
| `GET|HEAD /v1/media/private?key={key}` | Deliver a private object with Firebase identity and a key-scoped capability; always `private,no-store`. |
| `GET|HEAD /v1/media/panorama?key={key}` | Deliver an approved tour derivative only with a short-lived, digest-bound publication capability issued by the trusted API backend; always `private,no-store`. |
| `GET /v1/internal/objects?cursor={cursor}&limit={1..1000}` | Return one paginated R2 bucket listing page for reconciliation. |
| `GET|HEAD|PUT|DELETE /v1/internal/object?key={key}` | Backend-only inspect, read, create, or delete a managed object. Delete confirms the key is absent before returning success. |
| `POST /v1/internal/publish?key={key}` | Backend-only publication marking for approved store media or a verified panorama derivative. |

The Worker publication marker alone does not publish a tour. The Firestore tour remains the publication authority: the migration API Worker (or retained Functions fallback) verifies every node and its review before marking derivative objects, then atomically rechecks the tour and quota state before changing the tour to `published`. Public access tokens are minted only after that Firestore status is published.

Panorama derivatives use the same upload route, but only at `tours/derivatives/{uid}/{tourId}/{nodeId}/{revisionId}_{sha256}.jpg`. Derivative keys are immutable and are never overwritten. Uploads require a known `Content-Length`; chunked or unknown-length bodies are rejected because R2's streaming `put` needs a known length. The Worker checks the length against the reserved maximum, verifies the initial JPEG/PNG/WebP signature while streaming through a fixed-length stream, uses an R2 conditional create to prevent overwrites/replays, and checks the R2-reported size before returning success. The migration API Worker verifies the reservation metadata, JPEG end marker, exact size, and R2-stored SHA-256 checksum from object metadata before finalizing quota accounting; it does not buffer the full derivative. The retained Functions fallback remains available for comparison until migration validation is complete. This byte verification does not establish that privacy detection or blurring was complete.

## Firebase and quota integration

The migration API Worker authenticates callers, enforces App Check and permissions, rate limits requests, reserves capacity in the `system_config/storage_quota` transaction, and mints short-lived ES256 capabilities when `LOCALSPOT_BACKEND_URL` is configured. The retained Functions path performs those checks only as a legacy fallback. Flutter sends both a Firebase ID token and the scoped upload capability to the Worker. The Worker enforces the declared upload length while streaming, rejects replayed reservation IDs, and stores only to the private R2 binding. The API Worker checks actual R2 size and signatures, sanitizes product/store images, and accounts for source and processed copies separately.

The hard bucket budget is 9,000,000,000 decimal bytes. All objects in the isolated trial bucket, including originals, every retained derivative revision, temporary, private, and public objects, count toward reconciliation. Other R2 buckets in the Cloudflare account are outside this bucket-level counter and must be accounted for separately when estimating account-wide free-tier use. The initial quota record is intentionally created by a successful reconciliation, never seeded to zero by application code. Any unexplained inventory mismatch pauses uploads.

Deletes go through Firestore ledger state and a verified Worker DELETE/HEAD result before used bytes are decremented. The legacy Functions path historically scheduled reconciliation; in the migration Worker, reconciliation is admin-triggered and is not scheduled until realistic inventory scans are measured against Free Cron CPU limits. The admin review screen can inspect the quota and delete listed orphan objects.

## Configuration and deployment boundary

Local protected routes intentionally fail closed until `GATEWAY_PUBLIC_JWKS` contains the public ES256 JWK set. The gateway receives only the public JWK in `GATEWAY_PUBLIC_JWKS`. For local emulator use, the API Worker reads a test-only `R2_GATEWAY_PRIVATE_JWK` from its ignored `.dev.vars` file. For an approved migration trial, configure the private JWK as an API Worker secret and `R2_GATEWAY_URL` as a Worker variable. The legacy fallback uses Firebase Functions Secret Manager and parameters. Never put production keys in Wrangler vars or `.dev.vars`, source control, Flutter, or chat. The Worker has no R2 API credentials; its `MEDIA_BUCKET` binding is sufficient.

Locentra uses Cloudflare R2 as its target object store. It has no Firebase Storage bucket and does not require Firebase Storage for media. The retained Firebase Functions implementation is not part of the no-Blaze migration target. This Wrangler config names the existing `locentra-upload-gateway` and `locentrastorage` resources; never deploy it or change those resources as part of this migration. Any authorized trial requires a separately named gateway and private R2 bucket. Configure the gateway public JWK and API Worker secrets only after separate approval, then reconcile the isolated bucket before enabling uploads. Uploads must remain disabled until the first full R2 inventory is clean and matches the ledger under the 9 GB limit.

## Verification performed locally

- `npm run typecheck` and `npm test` in `cloudflare/worker` (20 authorization, upload, private/public delivery, publication, and deletion tests in the latest recorded run).
- Historical legacy Functions verification: `npm run typecheck`, `npm run build`, and panorama review/derivative verification smoke tests passed; Functions are retained for comparison and are not part of the target deployment.
- `firebase emulators:exec --project demo-localspot-r2 --only firestore "node scripts/r2_quota_emulator_smoke.cjs"` (concurrent reservation rejection, release idempotency, actual-byte finalization, failed deletion preservation, and successful retry-safe deletion).
- `flutter test` and a local Android debug APK build.
- Android panorama geometry unit tests.

Flutter analysis currently reports informational lint findings in the pre-existing prototype formatting and one async-context location; it reports no analyzer errors. Tests and builds are local/emulated only.

These are local/emulated checks. The Worker has not been deployed, and no live R2 upload, account-wide quota check, or production Firebase callable test has been performed.
