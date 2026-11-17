# Locentra Worker security design and review

**Status: local code review, not a production security approval.** The Worker is emulator-configured and has no production secrets or endpoint.

Local credential hygiene check: the Worker `.dev.vars` files and Android signing properties/keystore exist locally and are ignored by Git. No tracked service-account credential, Worker secret file, `key.properties`, or private keystore path was found. `google-services.json` and `firebase_options.dart` remain tracked Firebase client configuration; they are not service-account private keys.

## Identity and app attestation

- Production Firebase ID tokens are verified with Google's Secure Token X.509 certificates. The Worker restricts algorithm to RS256 and checks signing-key ID, issuer, project audience, expiry, issue time, subject UID format, and `auth_time`.
- Protected requests require `X-Firebase-AppCheck`. The Worker verifies the App Check JWT using Firebase's published JWKS and checks issuer, project audience, issue time, subject, and the required `FIREBASE_ANDROID_APP_ID`. Production requests fail closed if that Android identity is not configured.
- After signature and App Check validation, each production request calls Identity Toolkit `accounts:lookup` with the ID token, then verifies the returned UID, disabled state, and `validSince` boundary. Missing/malformed account state or an unavailable Auth API fails closed. This requires the Firebase Web API key Worker variable for all protected routes; the emulator-only path skips this remote check.
- Emulator bypass is accepted only when `LOCAL_EMULATORS=true`, the project ID is exactly `demo-localspot`, and the Auth emulator URL is set. The checked-in Wrangler config is emulator-only.
- Sensitive account deletion requires recent Firebase authentication. Other routes perform role, ownership, store-grant, media-state, and linkage checks in their handler before writing through Firestore REST.

## Firestore authority

The Worker uses OAuth with `FIREBASE_SERVICE_ACCOUNT_JSON` and Firestore REST. Google's REST guidance specifies the `https://www.googleapis.com/auth/datastore` scope and IAM authorization; service-account requests bypass Firestore Security Rules. The documented `roles/datastore.user` role grants broad entity read/write access. A narrower custom project role is a candidate: `datastore.databases.get` plus `datastore.entities.create`, `delete`, `get`, `list`, and `update`, which cover the REST methods this Worker uses (transactions, document reads, queries/aggregations, and writes). This remains database-wide authority rather than collection-level scope; the Worker must enforce collection, ownership, role, and validation boundaries. Do not grant Owner or Editor. The secret is absent from local config and must never enter Flutter or Git. Official docs confirm the OAuth/IAM mechanism and Spark Firestore quotas, but do not explicitly establish that setting up a service account/custom role requires no billing. No such account was provisioned and no OAuth exchange was run against a Spark project, so the no-billing gate remains unverified. Do not link billing to test this. References: [Firestore REST authentication](https://docs.cloud.google.com/firestore/native/docs/use-rest-api), [Firestore IAM method permissions and custom roles](https://docs.cloud.google.com/firestore/native/docs/security/iam), [Firebase Spark plan](https://firebase.google.com/docs/projects/billing/firebase-pricing-plans).

## Media and quota boundaries

- R2 remains private; the Worker does not return raw R2 credentials. Gateway capabilities are signed with `R2_GATEWAY_PRIVATE_JWK` and sent to the configured HTTPS gateway URL.
- Object keys are validated against the authenticated UID, upload reservations bind size, purpose, media type, and ownership, and finalization checks stored metadata and accounting before allowing subsequent workflows.
- Quota reservation and release use Firestore transactions. Deletion confirms object removal before releasing counted bytes. Panorama derivative keys are immutable; publication verifies the exact derivative digest and owner review state.
- The app's 9,000,000,000-byte limit does not prevent account-level R2 overage if other buckets consume the shared free allowance.

## Known gaps before production

- Account status and revocation checks add an Auth API round trip to every production request. Measure request latency and Authentication quotas in the isolated trial; the check has unit coverage but has not yet been exercised against a production Firebase Auth project.
- Firestore service-account IAM scope and a successful OAuth exchange on an isolated Spark project remain unverified. Keep the principal limited to Firestore data access and do not grant Owner/Editor.
- Production App Check Android app ID, Play Integrity settings, rate-limit thresholds, CORS/origin behavior, and HTTPS gateway configuration need project-specific review.
- Whole-bucket reconciliation is not scheduled and has no realistic-scale CPU measurement. Every-15-minute media cleanup is resumable and bounded, but still needs Cloudflare CPU/subrequest measurement.
- The Worker verifies owner review as an attestation; it cannot prove that panorama pixels contain no unblurred faces or people.

## Security validation

The local emulator suite covers authenticated flows and mocked gateway behavior where emulators are available. Production token-key rotation, revocation, App Check enforcement, Firestore IAM, gateway signature interoperability, real R2 privacy, over-quota concurrency, and Android release configuration have not been validated against isolated trial resources. See [CLOUDFLARE_FUNCTIONS_MIGRATION.md](CLOUDFLARE_FUNCTIONS_MIGRATION.md) and [LOCALSPOT_FREE_TRIAL_DEPLOYMENT.md](LOCALSPOT_FREE_TRIAL_DEPLOYMENT.md).
