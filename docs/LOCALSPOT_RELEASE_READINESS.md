# LocalSpot release readiness

**Audit date:** 2026-11-16  
**Decision:** **Not ready for trial distribution.** Current debug and automated checks pass in part, but there is no isolated trial cloud environment, no signed release artifact, and critical integrated media operations have not been validated against live R2.

## Environment boundary

The checked-in Firebase app configuration targets `capstone-project-561a2`; it is not a trial configuration. Cloudflare account inspection found one bucket, `locentrastorage` (APAC, Standard, 0 objects / 0 bytes at inspection, public `r2.dev` disabled), and an existing deployed Worker named `locentra-upload-gateway`. Its checked-in Wrangler configuration binds that bucket and sets `FIREBASE_PROJECT_ID` to the configured Firebase project. Neither resource is designated an isolated trial target, so neither is safe to reuse. No deployment or live object operation was performed in this audit.

The actual Flutter debug build is isolated: it requires explicit emulator opt-in, requires project `demo-localspot` and an explicit host, and the debug-only manifest removes FirebaseInitProvider. Release rejects emulator configuration. The trial APK must be rebuilt against a newly registered trial Firebase project and public Worker URL; the current debug APK is not suitable for distribution.

## Feature status

| Area | Status | Evidence / remaining work |
|---|---|---|
| Registration, sign-in, sign-out, password recovery | Implemented but not fully verified | Firebase Auth integration exists. Current automated tests cover app/auth flows in mocks and emulator suite; no fresh full physical matrix for registration/recovery/network expiration was completed in this audit. |
| Profile loading and role recognition | Working and verified for the tested owner path | Physical Infinix X6873 owner sign-in resolved `users/{authUid}` from the emulator and opened the tour editor. Loading, unavailable, failed, customer, owner, and admin states are represented in app code/tests. Fresh customer/admin/missing/error physical runs were not repeated in this release audit. |
| Owner/admin authorization | Implemented; backend checks present | Callable authorization tests and Firestore rules tests passed in the local emulator suite. Never rely on Flutter role state as authorization. Live trial verification remains required. |
| Store applications, dashboards, edit/moderation | Implemented but not fully verified | Screens and callable/rules paths exist. Full physical application, approval/rejection, ownership-denial, and image workflow were not exercised end to end. |
| Product create/edit/delete, categories, inventory, search | Implemented but not fully verified | Flutter smoke tests exercise catalog/search and selected access rules. Physical product CRUD and live media upload/deletion were not completed. |
| Product/store image display and upload | Implemented but not fully verified | Secure gateway and backend quota/verification code exist. Worker tests use mocked R2. No live trial upload, download, or verified deletion has been performed. |
| Nearby discovery, search/filter, location, map/routing | Implemented but not fully verified | Widget tests include search, location lifecycle, and route preconditions. Device permission, GPS, map-provider key, live routing, and poor-network behavior remain unverified. |
| Promotions/advertising | Implemented but not fully verified | App tests exercise expiration and permission boundaries; no complete physical owner creation/moderation/display journey. |
| Panorama selection and on-device detector | Implemented but not fully verified | Infinix processed Wikimania fixture at original 6528×3264 output, 12.142 seconds in a prior integration run. Detector counts are not accuracy evidence. Camera picker was not validated. |
| Full-resolution JPEG derivative and manual spherical blur | Partially verified | Physical seam-adjacent add/move/remove, undo/redo, persistence/restart, regeneration and review invalidation are documented. Resize, pole coverage, and quantitative full-sphere alignment remain unverified. JPEG only is supported by the integrated processor. |
| 360° viewer and 48-direction owner review | Partially verified | Review screen and first presented-direction transition were exercised; device reached 1/48. Full 48 directions, acknowledgements, submission, and complete edit-after-review journey were not completed. Owner attestation is not proof of complete privacy detection. |
| Authenticated review, derivative verification, quota and publication | Implemented; local tests only | Functions smoke tests validate review binding and digest-scoped derivative verification. Local quota emulator tests validate reservation/finalization/deletion. No integrated upload-to-publication journey was completed. |
| Private original retrieval and approved public delivery | Implemented in source; not fully verified | Worker tests cover mocked bucket authorization. No real R2 private/public retrieval has been performed. The original must remain private; public delivery must be through Worker authorization. |
| Admin dashboard, moderation, user management/reporting | Implemented but not fully verified | Source and tests cover selected permissions; no physical admin or full moderation workflow was executed. |
| Crash reporting, App Check, operational recovery | Blocked by trial configuration | Release code expects Play Integrity and configured Firebase; no trial app registration, App Check enforcement validation, crash-reporting verification, restore drill, or alerting setup is complete. |
| Trial APK/AAB | Blocked by external configuration | No trial Firebase project/app ID or release keystore exists. Release task fails closed and will not sign with debug key. |

## Current code and verification

- Firebase Storage is not an active application dependency. `firebase.json` no longer configures a Storage emulator. The legacy unused `storage.rules` and `scripts/storage_rules_smoke.cjs` files remain in the repository but are not part of the app or current smoke script. No bucket creation or Blaze enablement for Firebase Storage is needed.
- R2 quota constant remains **9,000,000,000 bytes**. Transactional reservations, actual stored-size finalization, retry-safe deletion, cleanup, and reconciliation code remain present.
- Local debug build uses Firebase emulators; local Wrangler R2 tests/smokes do not establish compatibility with Cloudflare's live R2 service.
- Full Flutter tests: **39 passed**. `flutter analyze lib test`: **clean**. Whole-repository `flutter analyze`: nonzero due 19 informational lint findings in the retained standalone prototype.
- Functions: TypeScript typecheck/build and sanitizer, panorama review, and derivative-verification smoke checks passed. Firebase emulator rules/access/auth/quota/cleanup suite passed in the local emulator environment in this audit run. No deployed Function was tested.
- Worker: **16 tests passed** and TypeScript typecheck passed. Worker tests use mocked R2.
- Android debug build installed and launched on Infinix X6873; emulator project and owner profile resolution were logged. App-owned native panorama geometry tests passed. The full Gradle dependency unit task remains failed by three `geolocator_android` dependency tests (Mockito setup exceptions); the app's own three projection tests passed.
- Release APK build was attempted and stopped at the guard because the trial application ID/project configuration is absent. No release APK or AAB was emitted.
- Physical workflow remains partial; see [PANORAMA_INTEGRATION_TEST_REPORT.md](PANORAMA_INTEGRATION_TEST_REPORT.md).

## Release gates

1. Obtain approval to create an isolated Firebase trial project (including the required billing association for deployed Cloud Functions), trial Android registration, separate Worker, and separate private R2 bucket. No such resources exist.
2. Configure isolated Firebase Auth, Firestore rules/indexes, Functions parameters/secrets, App Check, and region. Verify debug/release project isolation.
3. Create and deploy only the trial Worker/Functions after configuration review; use a trial-only ES256 signing pair, keeping its private key in Secret Manager and publishing only its public JWKS to the Worker.
4. Run first reconciliation against the trial bucket. Keep uploads disabled until R2 object inventory and Firestore quota ledgers reconcile exactly. Preserve the 9,000,000,000-byte hard limit.
5. Exercise controlled real trial R2 upload, read, private access, digest verification, quota finalization, deletion, retry, and approved public delivery. Test denied/expired/cross-object cases.
6. Finish physical customer/owner/admin, store/product, image, network-failure and panorama workflows. Complete the genuine 48-direction owner review and integrated media path. Panorama publication stays disabled until those checks pass.
7. Select a non-placeholder application ID, create a protected release keystore and local ignored `android/key.properties`, then produce and verify signed ARM64 APK and AAB.
8. Complete crash reporting, feedback route, privacy/data-retention text, recovery and budget monitoring before distributing to testers.

## Approval boundary

No resources, billing settings, production data, deployment, real R2 objects, or production secrets were modified by this audit. Live trial resource creation is blocked pending the user's explicit approval of the isolated Firebase/billing and Cloudflare resource setup described in [LOCALSPOT_TRIAL_DEPLOYMENT.md](LOCALSPOT_TRIAL_DEPLOYMENT.md).
