# LocalSpot trial deployment runbook

**Status: planning only. No isolated trial environment exists and no deployment has been made.** This document intentionally contains no secrets and no deployed trial endpoint.

## Existing account inventory (read-only)

- Firebase CLI had no active selected project. The account's project listing showed `capstone-project-561a2` and `activity-de9b4`; neither is designated LocalSpot trial. App configuration points to `capstone-project-561a2`. A Functions deployment listing could not be verified during inventory.
- Cloudflare account inventory contained `locentrastorage`, APAC/Standard, empty at inspection (0 objects, 0 bytes), with public `r2.dev` disabled and no custom domain. Do not assume an empty bucket is safe for trial use.
- Worker `locentra-upload-gateway` has deployment history and its repository config binds `locentrastorage` with `FIREBASE_PROJECT_ID=capstone-project-561a2`. It is not a trial deployment and must not be overwritten or used for trial.
- Therefore the trial requires a dedicated Firebase project, registered trial Android app, separate private R2 bucket, and differently named Worker. No current resource is approved or confirmed as trial.

## Cost and billing approval required

Cloud Functions deployment requires a Firebase project on the Blaze pay-as-you-go plan. Cloud Functions charges vary by region, invocations, compute, network, and associated services; budget alerts are not hard spending caps. See [Firebase pricing plans](https://firebase.google.com/docs/projects/billing/firebase-pricing-plans) and [Cloud Functions FAQ](https://firebase.google.com/docs/functions/faq-and-troubleshooting).

Cloudflare R2 currently includes 10 GB-month of Standard storage and monthly free request allowances (1 million Class A and 10 million Class B); published overage rates include $0.015/GB-month Standard storage, $4.50/million Class A, and $0.36/million Class B operations; egress is free. Usage above free tiers can incur charges. See [Cloudflare R2 pricing](https://developers.cloudflare.com/r2/pricing/). Worker plan limits/pricing must be checked against the account at setup time; do not assume free capacity.

Before resource creation, obtain explicit approval for: (a) a new Firebase project and Blaze billing association, (b) a new private R2 trial bucket and separate Worker, and (c) any account plan changes or expected overage exposure. Set usage alerts and service limits where available, while recognizing alerts do not cap spend. No billing setting has been changed.

## Required configuration, after approval

1. Create a dedicated Firebase trial project and register the selected Android package ID. Keep it separate from `capstone-project-561a2` and `activity-de9b4`.
2. Enable only required Firebase Authentication providers. Deploy reviewed Firestore rules and indexes, Functions, App Check, and the current Functions region `asia-southeast1`. Use separate test accounts and data.
3. Create a distinct, private R2 bucket. Keep public `r2.dev` disabled and do not attach a direct public R2 domain. Create a distinct Worker name/config using only that bucket and the trial Firebase project ID.
4. Generate an ES256 key pair on a trusted local workstation using the project's key-generation utility. Never print the private JWK. Store the private JWK as Firebase Functions Secret Manager secret `R2_GATEWAY_PRIVATE_JWK`; provide only the public JWKS as Worker variable `GATEWAY_PUBLIC_JWKS`. Keep a protected offline backup and rotate by publishing overlapping public keys, switching the signer to the new `kid`, verifying traffic, then removing the old public key only after old tokens expire.
5. Set Functions parameter `R2_GATEWAY_URL` to the deployed HTTPS Worker origin. Do not use localhost, Wrangler local mode, or a PC LAN IP in the trial app/backend.
6. Confirm Worker Firebase project verification, upload authorization, private-media capability checks, public publication checks, CORS allowlist, and R2 binding before deploying.
7. Deploy the trial Worker first with its trial project ID and public JWKS. Deploy trial Functions with the matching private signing secret and Worker URL. Confirm both endpoints before opening the app.
8. Initialize trial quota ledger with `storageProvider=cloudflare_r2`, `limitBytes=9000000000`, uploads disabled, and maintenance lock enabled. Run the backend's first reconciliation against the actual trial bucket; compare object keys, byte lengths, metadata and ledger totals. Enable uploads only after an operator reviews a zero-mismatch reconciliation and the ledger matches actual bucket contents.
9. Run controlled trial-only upload/get/private-get/delete flows and verify actual bytes, content type and backend-calculated SHA-256. Confirm deletion before quota release. Keep original panoramas private. Publish only derivative digests with current authenticated owner review, finalized quota and backend publication authorization.

## Local PowerShell commands (execute only after resource approval)

Use explicit trial IDs; never copy the production project ID into these variables.

```powershell
$trialProject = "<approved-trial-firebase-project-id>"
$trialWorkerDir = "cloudflare/worker"
firebase use $trialProject
firebase deploy --project $trialProject --only firestore:rules,firestore:indexes,functions
Push-Location $trialWorkerDir
npx wrangler deploy --config wrangler.trial.jsonc
Pop-Location
```

The deploy commands are examples, not a recommendation to run before a reviewed `wrangler.trial.jsonc`, trial secrets, and billing approval exist. The current `wrangler.jsonc` targets the existing Worker/bucket and must not be deployed for this trial.

## Android endpoint and signing controls

The debug build is emulator-only. Trial release requires fresh `google-services.json` and `lib/firebase_options.dart` generated for the trial project and matching registered app. The release Gradle guard checks that project, app ID, and private keystore configuration match; it rejects the known production project and never uses the debug key. Keep `android/key.properties` and the keystore outside Git. Setup details: [ANDROID_RELEASE_SIGNING.md](ANDROID_RELEASE_SIGNING.md).

The Flutter client must contain no R2 credentials or private signing keys. It calls Firebase Functions and receives only short-lived, object-scoped authorization for the deployed Worker. The Worker verifies signed requests and keeps the R2 bucket private.

## Blockers

- User approval for Firebase project creation and Blaze billing association.
- User approval for a separate R2 bucket and Worker; account plan/usage costs to be confirmed.
- Trial project/app registration and trial Firestore/Auth/App Check configuration.
- Trial-only Worker config, ES256 keypair, Secret Manager secret, and HTTPS `R2_GATEWAY_URL`.
- Successful first reconciliation and real R2 security/quota tests.
- Trial package ID and protected release signing key.
