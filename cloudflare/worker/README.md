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

The local health endpoint is `GET http://localhost:8787/healthz`. Protected routes fail closed until `GATEWAY_PUBLIC_JWKS` is configured. Do not put a private signing key in this Worker; Firebase Functions will hold the ES256 private JWK in Secret Manager and this Worker receives only the matching public JWK set.

## Authorization contract for the Firebase backend

User-facing upload and private-media requests carry two independent credentials:

- `Authorization: Bearer <Firebase ID token>`; this Worker verifies the token signature against Firebase's published certificates and checks the project audience, issuer, expiry, and subject.
- `X-Upload-Authorization: Bearer <ES256 JWT>` for uploads, or `X-Gateway-Authorization: Bearer <ES256 JWT>` for private reads. The Firebase callable creates this short-lived token only after App Check, ownership, permission, size, rate-limit, and Firestore reservation checks succeed.

Gateway tokens use issuer `localspot-functions`, audience `locentra-upload-gateway`, ES256, a `kid`, `iat`, `exp`, `jti`, and `sub`. Their lifetime is at most five minutes. Upload tokens also include `scope: "upload"`, `objectKey`, `contentType`, `maxBytes`, `mediaType`, `assetId`, and `tourId` for panoramas. Derivative tokens additionally bind `nodeId`, an immutable `revisionId`, and the expected SHA-256 digest. The Worker derives the expected UID-scoped key from signed claims and rejects mismatches. The Flutter app never receives an R2 credential or a token that permits arbitrary object keys.

Private reads use `scope: "media:read"`, `objectKey`, and a `sub` equal to the verified Firebase UID. Firebase Functions must authorize store-owner/admin access before minting this capability.

Public panorama reads use a separate `scope: "media:public-read"` capability bound to the exact derivative key, tour ID, viewpoint ID, and SHA-256 digest. Firebase Functions issue it only after checking the published Firestore tour, current owner attestation, verified derivative metadata, finalized quota ledger, and R2 object metadata. The panorama route is not a direct public object URL: guessing a derivative key is insufficient. The Worker additionally requires the object publication marker and matching digest. Responses are `private,no-store`; the short-lived capability is presented in `X-Gateway-Authorization`.

Backend-only tokens use the same issuer, audience, algorithm, and lifetime, but are minted by Firebase Functions and sent as `X-Gateway-Authorization`. Supported scopes are `objects:list`, `object:head`, `object:get`, `object:put`, and `object:delete`. Object-scoped tokens include the exact `objectKey`; writes also include `maxBytes`. Keep the corresponding private key in Firebase Secret Manager. The public JWKS is configuration, not a secret.

## Routes

| Route | Purpose |
| --- | --- |
| `PUT /v1/uploads/{reservationId}` | Store a reserved product, store, or panorama original in its UID-scoped quarantine path. |
| `GET|HEAD /v1/media/public/{encodedKey}` | Deliver only product/store public-prefix objects with a one-day cache policy. |
| `GET|HEAD /v1/media/private?key={key}` | Deliver a private object with Firebase identity and a key-scoped capability; always `private,no-store`. |
| `GET|HEAD /v1/media/panorama?key={key}` | Deliver an approved tour derivative only with a short-lived, digest-bound Firebase Functions publication capability; always `private,no-store`. |
| `GET /v1/internal/objects?cursor={cursor}&limit={1..1000}` | Return one paginated R2 bucket listing page for reconciliation. |
| `GET|HEAD|PUT|DELETE /v1/internal/object?key={key}` | Backend-only inspect, read, create, or delete a managed object. Delete confirms the key is absent before returning success. |
| `POST /v1/internal/publish?key={key}` | Backend-only publication marking for approved store media or a verified panorama derivative. |

The Worker publication marker alone does not publish a tour. The Firestore tour remains the publication authority: the Functions callable verifies every node and its review before marking derivative objects, then atomically rechecks the tour and quota state before changing the tour to `published`. Public access tokens are minted only after that Firestore status is published.

Panorama derivatives use the same upload route, but only at `tours/derivatives/{uid}/{tourId}/{nodeId}/{revisionId}_{sha256}.jpg`. Derivative keys are immutable and are never overwritten. Uploads require a known `Content-Length`; chunked or unknown-length bodies are rejected because R2's streaming `put` needs a known length. The Worker checks the length against the reserved maximum, verifies the initial JPEG/PNG/WebP signature while streaming through a fixed-length stream, uses an R2 conditional create to prevent overwrites/replays, and checks the R2-reported size before returning success. Firebase Functions then independently read the stored derivative, verify owner/reservation metadata, JPEG structure, exact size and SHA-256, and finalize quota accounting. This byte verification does not establish that privacy detection or blurring was complete.

## Firebase and quota integration

Firebase Functions authenticate callers, enforce App Check and permissions, rate limit requests, reserve capacity in the `system_config/storage_quota` transaction, and mint short-lived ES256 capabilities. Flutter sends both a Firebase ID token and the scoped upload capability to the Worker. The Worker enforces the declared upload length while streaming, rejects replayed reservation IDs, and stores only to the private R2 binding. Functions inspect actual R2 size and file signatures, sanitize product/store images, and account for source and processed copies separately.

The hard bucket budget is 9,000,000,000 decimal bytes. All objects in `locentrastorage`, including originals, every retained derivative revision, temporary, private, and public objects, count toward reconciliation. Other R2 buckets in the Cloudflare account are outside this bucket-level counter and must be accounted for separately when estimating account-wide free-tier use. The initial quota record is intentionally created by a successful reconciliation, never seeded to zero by application code. Any unexplained inventory mismatch pauses uploads.

Deletes go through Firestore ledger state and a verified Worker DELETE/HEAD result before used bytes are decremented. A scheduled reconciliation and admin callable compare paginated bucket inventory with the ledger. The admin review screen can inspect the quota and delete listed orphan objects.

## Configuration and deployment boundary

Local protected routes intentionally fail closed until `GATEWAY_PUBLIC_JWKS` contains the public ES256 JWK set. The corresponding private JWK belongs only in Firebase Secret Manager as `R2_GATEWAY_PRIVATE_JWK`. Configure `R2_GATEWAY_URL` in Firebase Functions with the deployed Worker HTTPS origin. Never put the private key in Wrangler vars, `.dev.vars`, source control, Flutter, or chat. The Worker has no R2 API credentials; its `MEDIA_BUCKET` binding is sufficient.

LocalSpot uses Cloudflare R2 as its only object store. It has no Firebase Storage bucket, does not migrate Firebase Storage media, and does not require Firebase Storage or the Blaze plan for media. Before any production uploads, set the Worker public JWK configuration and Functions secrets/parameters, deploy only after explicit approval, then run the admin reconciliation. Uploads must remain disabled until the first full R2 inventory is clean and matches the ledger under the 9 GB limit.

## Verification performed locally

- `npm run typecheck` and `npm test` in `cloudflare/worker` (16 authorization, upload, private/public delivery, publication, and deletion tests).
- `npm run typecheck`, `npm run build`, and panorama review/derivative verification smoke tests in `functions`.
- `firebase emulators:exec --project demo-localspot-r2 --only firestore "node scripts/r2_quota_emulator_smoke.cjs"` (concurrent reservation rejection, release idempotency, actual-byte finalization, failed deletion preservation, and successful retry-safe deletion).
- `flutter test` and a local Android debug APK build.
- Android panorama geometry unit tests.

Flutter analysis currently reports informational lint findings in the pre-existing prototype formatting and one async-context location; it reports no analyzer errors. Tests and builds are local/emulated only.

These are local/emulated checks. The Worker has not been deployed, and no live R2 upload, account-wide quota check, or production Firebase callable test has been performed.
