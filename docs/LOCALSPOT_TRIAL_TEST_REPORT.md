# LocalSpot trial test report

**Date:** 2026-11-16  
**Environment:** Windows 11 development workspace, Firebase emulators, Wrangler local test tooling, and physical Infinix X6873 (Android 16/API 36/arm64). **No Cloudflare deployment or real R2 object operations occurred.**

## Results

| Component | Result | Scope / caveat |
|---|---|---|
| Flutter test suite | **39 passed** | Current full suite, run with `flutter test --reporter compact`. |
| Flutter analyzer | **Passed for `lib test`** | `flutter analyze lib test`: no issues. Full repository analyzer remains nonzero on 19 info-level prototype lints. |
| Flutter Android debug build | **Passed** | Emulator-configured debug APK built. This is not a trial release artifact. |
| Flutter release build | **Blocked as intended** | Guard rejected missing `localspotReleaseApplicationId`; project/app registration and release signing key are absent. No release artifact was produced. |
| Physical Android smoke | **Partial pass** | APK installed/launched on Infinix X6873. Debug logs verified Firebase project `demo-localspot`, auth UID/profile path match and owner role; owner tour editor opened. Not a full feature workflow. |
| Physical panorama | **Partial, prior recorded run** | Wikimania fixture processed at 6528×3264, 12.142 seconds, output 2,190,799 bytes. Seam-adjacent edit and derivative regeneration/review invalidation observed. Full manual edit, 48/48 review, upload and publication did not complete. |
| Android native tests | **Partial / dependency failure** | App-owned panorama projection tests passed (3). Full Gradle unit task failed in three `geolocator_android` dependency tests during Mockito setup. |
| Functions typecheck/build | **Passed** | `npm run typecheck`, `npm run build`. |
| Functions smoke tests | **Passed** | Sanitizer (JPEG/PNG/WebP/malformed/unsupported), panorama review (48 unique directions, acknowledgements, digest/version, caller UID exclusion), derivative verification (immutable key, ownership/reservation, content type, actual size, JPEG structure, SHA-256). |
| Firebase emulator tests | **Passed in local emulator run** | Rules/access/auth/profile/quota/cleanup smoke suite passed against demo project. Quota smoke included concurrent reservations, over-limit rejection, release, actual-byte finalization, failed deletion and retry-safe deletion. |
| Worker tests/typecheck | **Passed** | 16 tests passed; TypeScript typecheck passed. These use mocked R2 bindings. |
| Wrangler local R2 | **Simulation only** | Local reconciliation previously reported 0 objects/0 bytes. No real R2 binding, real upload, download, deletion, or cryptographic backend validation against live bytes occurred. |
| Live Cloudflare R2 | **Not run** | No actual R2 object requests were made. |

## Physical and workflow limitations

The prior integration report documents the physical role fix, fixture identity, on-device processing, and partial manual correction. It also records that resize and polar alignment were not verified, review had reached only 1/48, owner review was not submitted, and no media upload/retrieval/publication workflow was completed. Physical camera/gallery selection, customer restrictions, store/product CRUD, network-failure recovery, and the full panorama journey have not all been validated on device.

## Cloud security and isolation findings

- Existing account resources are not isolated trial resources: `locentrastorage` is an existing private empty bucket, and `locentra-upload-gateway` has deployment history and configuration tied to the configured Firebase project. They were not reused or changed.
- There is no confirmed dedicated trial Firebase project. `firebase use` had no active project. The configured Android app points to `capstone-project-561a2`; it is rejected by the release guard for trial use.
- Functions deployment listing could not be verified. No Worker or Functions deployment was attempted.
- Current release-signing files are absent (`android/key.properties` and upload keystore not found). No APK/AAB signed for distribution exists.
- No production Firestore changes, R2 writes, deletions, quota changes, billing changes, or secret rotations occurred.
- No Firebase Storage bucket/dependency was introduced. Local simulation and mock tests are not evidence of live R2 compatibility.

## Failures and blockers

1. Full integrated media journey remains untested: actual reserve → upload → object verification → SHA-256 → quota finalize → review persistence → publish → Worker delivery.
2. Live R2 private/public fetch, mutation rejection, deletion and quota reconciliation are untested.
3. Three `geolocator_android` dependency unit tests fail during Mockito initialization; app-owned projection tests pass.
4. Whole-repository `flutter analyze` reports 19 informational lints in the standalone prototype; integrated `lib` and `test` analyze cleanly.
5. The trial backend requires a dedicated Firebase project (and billing association for Functions), trial-only Worker/R2 resources, keys/secrets and initial reconciliation.
6. The Android release needs a selected trial package ID, matching Firebase Android registration/config, private release key and a successful signed APK/AAB build.
7. Full physical user-role matrix, image/store/product journeys, complete 48-direction review, and panorama publication remain incomplete.

## Readiness decision

**Not distributable.** Keep release uploads and panorama publication disabled. Proceed only after resource approval, creation of isolated trial infrastructure, successful first reconciliation, real trial R2 end-to-end/security tests, physical workflow completion, and signed release build verification. See [LOCALSPOT_RELEASE_READINESS.md](LOCALSPOT_RELEASE_READINESS.md) and [LOCALSPOT_TRIAL_DEPLOYMENT.md](LOCALSPOT_TRIAL_DEPLOYMENT.md).
