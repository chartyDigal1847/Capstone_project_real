# LocalSpot Panorama Integration Test Report

**Date:** 2026-11-16  
**Status:** Physical owner-role issue fixed; integrated physical media test remains partial; production cutover is **not ready**.

## Summary

Local Firebase emulators and Wrangler's local R2 binding were used. No Cloudflare Worker or Firebase Function was deployed, and no production R2 bucket was used. A first diagnostic app build, before emulator project selection was corrected, did issue read-only Firestore reads against the production-configured Firebase project; no production writes were made. Subsequent physical-device operations used `demo-localspot`. No panorama was uploaded during this run. Wrangler reconciliation reported zero objects and zero bytes, so this report does **not** establish live Cloudflare R2 compatibility.

The code-level and emulator authorization checks passed. The physical role defect was traced to the FlutterFire emulator path: FlutterFire remapped the loopback emulator address to `10.0.2.2`, which is reserved for Android emulators and is not reachable from the Infinix. A server profile read failure was then silently converted to the default `customer` role. Both behaviors have been corrected for local debug use. The Infinix now resolves owner status and opens the tour editor. Full upload/review/publication is still not complete; see the physical follow-up below.

## Test environment

- Firebase Auth, Firestore, and Functions emulators: project `demo-localspot`; bound to the development host for the physical phone.
- Cloudflare Wrangler v4.162.0 development server: local mode, local R2 binding/storage simulation. No real R2 bucket was bound.
- Firebase CLI: 15.34.2.
- Physical Android: Infinix X6873, Android 16/API 36, arm64.
- Additional Android emulator: `emulator-5554` attached; the end-to-end Flutter journey was attempted on the physical device.
- Test panoramas available locally: `35C3_Panorama.jpg` (12,563,809 bytes) and `Wikimania_2023_360_group_photo.jpg` (11,690,366 bytes). Both were copied to the device's test Pictures folder in the prior setup, but neither was processed in this integrated run.
- The working-tree status was captured before testing. Existing uncommitted R2 and panorama changes were not reset, stashed, or discarded.

## Results

| Area | Test/result |
|---|---|
| Flutter tests | Earlier integration suite: **32 passed**. Role follow-up: `flutter test test/auth_profile_test.dart test/app_smoke_test.dart`: **25 passed**. |
| Integrated source analysis | Follow-up `flutter analyze lib test`: **passed**, no issues. |
| Whole-repository analysis | `flutter analyze`: **nonzero exit**, reporting 19 `info`-level lint items in the retained standalone prototype (`prototypes/panorama_privacy_prototype`). No new `lib` or `test` diagnostics when analyzed separately. |
| Firebase Functions | `npm run build`: **passed**. The Functions package has no generic `test` script; dedicated panorama review and derivative smoke scripts were run and passed. |
| Panorama review validation | **Passed**: 48 unique directions, both acknowledgements, processing version and digest validation, and caller-supplied UID exclusion. |
| Derivative verification | **Passed**: immutable digest-scoped key, owner/reservation metadata, content type, actual byte count, JPEG structure, and SHA-256 checks. These are local smoke tests, not uploaded-object E2E verification. |
| Cloudflare Worker | `npm test`: **16 passed**; `npx tsc --noEmit`: **passed**. Tests use a mocked R2 bucket. |
| Android Gradle unit task | `gradlew testDebugUnitTest`: **failed** in the dependency `geolocator_android:testDebugUnitTest` (3 tests). The reported cause chain includes Mockito setup `IllegalArgumentException`/`IllegalStateException`, followed by `NullPointerException`; this is in the plugin's tests, not a panorama assertion. The app's Flutter debug compilation task ran as part of the Gradle invocation. |
| Local R2 reconciliation | Admin callable completed against Wrangler local storage: 0 objects, 0 bytes, 0 missing, 0 orphaned, 0 size mismatches, 0 pending reservations. The reconciliation was rerun after the quota smoke test. |
| Quota accounting | `r2_quota_emulator_smoke.cjs`: **passed** concurrent reservation (only one 5 GB reservation fits), over-limit rejection, idempotent release, actual-byte finalization, failed deletion retaining quota, and retry-safe verified deletion. The code constant remains the 9,000,000,000-byte application limit. No quota protection was changed for this test. |

## Integrated physical workflow

| Step | Result |
|---|---|
| Firebase Auth emulator sign-in | **Passed** on Infinix using the seeded owner account. |
| Authenticated Firestore owner profile | Emulator REST read with that same Auth ID token returned `role: owner` and the expected test store. |
| Flutter role resolution | **Passed after fix**: physical log shows project `demo-localspot`, profile path pattern `users/{authUid}`, `authUidMatches=true`, `source=server`, and `role=owner`. The owner home shows “Role Test Store” and the 360° tour editor opens. |
| JPEG fixture identity | **Passed**: debug-only app-private loader showed Wikimania filename, 6528×3264, 11,690,366 bytes, SHA-256 `c2ea88d1d01543ce4123235bb1fd39bd28498dc5458cb7d519e50e112b2f0315`; device file SHA matched. 35C3 was also present as 18000×9000, 12,563,809 bytes, SHA-256 `5af25da7706ce6dad1b67dbcec01953a44811a386ce5cf7d12daf1cc5c557a3e`. |
| On-device panorama processing | **Passed for Wikimania after JNI fix**: 6528×3264 derivative, 2,219,329 bytes, 12,142 ms, 303 face detections and 73 person detections across 14 views. Counts are detections, not accuracy. A prior run exposed and failed on a JNI symbol mismatch; exact package-mangled symbol was fixed and the rerun succeeded. |
| Manual correction / regeneration | **Partial**: added a seam-adjacent manual mask (longitude about −174.6°), UI marked the prior derivative stale and disabled review; changing the mask moved it to about −164.5°. Regeneration from the corrected source completed and cleared the stale-review warning, producing derivative SHA-256 `7c6f69cdc09899c8ca6f686cdf89119586cfaabad1abbb4621a6168aa51e8f54`, 6528×3264, 2,190,799 bytes. Physical resize, undo/redo, removal, restart persistence, and full-sphere alignment were not all verified. |
| 48-direction review and authenticated submission | **Review UI opened; owner review not completed**. The display showed 0/48 directions. No directions were falsely marked inspected and no review was submitted. It requires genuine visual inspection of every direction and owner acknowledgement. |
| Original/derivative uploads and progress | **Not run**; no objects were written to local R2. |
| Backend object verification and quota finalization on an uploaded derivative | **Not run end to end**; only unit/smoke validation ran. |
| Private original and derivative retrieval in Flutter | **Not run end to end**. |
| Publication and public Worker viewing | **Not run end to end**. |
| Camera selection | **Not validated**. Gallery test fixtures were staged, but the app never reached the panorama selection screen. |
| Crash/OOM/performance | No panorama processing was run in this integrated session; no new processing performance or OOM claim is made. |

A prior physical test exposed an empty-name avatar `RangeError`; the profile now renders its fallback avatar without crashing. The separate role-resolution failure remains.

## Security validation

### Direct emulator checks

- Unauthenticated `recordTourPanoramaReview`: **401 UNAUTHENTICATED**.
- Different owner's review request for the seeded owner's draft tour: **403 PERMISSION_DENIED**.
- Different owner's private-panorama access request: **403 PERMISSION_DENIED**.
- Unauthenticated private-panorama access: **401 UNAUTHENTICATED**.
- Publication of a draft tour with no reviewed viewpoints: **rejected** with `FAILED_PRECONDITION`.
- Authenticated direct Firestore tour write: **403 PERMISSION_DENIED** under the configured rules.
- The review validation smoke check confirms the owner UID is sourced from callable auth, not from a caller-supplied UID field.

### Worker tests using mocked R2

The 16 tests cover Firebase authentication, upload signatures and limits, immutable panorama derivative keys, content type and body-length rejection, replay rejection, public-prefix restrictions, unpublished derivative denial, signed publication authorization, digest-bound panorama reads, wrong digest/key scoping, private no-store responses, signed listing, and deletion behavior. These checks validate Worker logic with the test bucket only. They are not a real Cloudflare R2 test.

## Failed tests and remaining blockers

1. **Physical media workflow remains incomplete.** The role issue is fixed, but full owner review, upload, retrieval, and publication were not performed.
2. **Owner attestation must be genuine.** The 48-direction review was deliberately left incomplete rather than auto-completing an owner's inspection.
3. **Manual editor physical validation remains partial.** Resize, undo/redo, removal, restart persistence, and full-sphere alignment still need physical verification.
4. **Android dependency unit suite fails.** Three `geolocator_android` unit tests fail in Mockito setup; investigate JDK/plugin compatibility or isolate app-owned Android unit tests before treating Android unit validation as green.
5. **Whole-repository analyzer exits nonzero.** Integrated `lib` and `test` are clean; retained prototype files have 19 informational style diagnostics.
6. **Worker emulator and local R2 simulator are not Cloudflare R2.** No actual Cloudflare account, R2 bucket, deployed Worker, or live object operation was exercised.
7. **No integrated bad-object/corrupted-digest upload was executed.** Digest and object metadata validation passed smoke/unit cases only.
8. **Physical failure injection for Firestore was not completed.** The owner/customer/admin/missing-profile scenarios passed in earlier physical checks; a controlled failed Firestore request was not proven on the handset in this follow-up.

## Production blockers and cutover conditions

- Resolve the physical app role mismatch and rerun the full owner journey on the Infinix.
- Exercise two real test panorama objects through local upload reservation, Worker storage, backend byte/content-type/SHA-256 verification, quota finalization, review binding, publication, private-original retrieval, and Worker public delivery. Include tampered content, missing-object, expired-token, cross-key, cross-tour, and cross-viewpoint negatives.
- Confirm physical camera/gallery selection, progress/cancellation/error states, processing, manual correction, full 48-direction owner review, and derivative invalidation after edits.
- Resolve or explicitly scope the `geolocator_android` unit failures; rerun all Android and application tests.
- Obtain a successful initial reconciliation against the **actual production R2 bucket** and verify Firestore quota ledgers match stored bytes before enabling production uploads. This report's zero-byte reconciliation is local-only.
- Review and approve deployment configuration, keys/secrets, Worker and Functions releases, and production cutover separately. No deployment approval is implied here.

## Cleanup and production-data statement

Temporary emulator accounts and test documents are local-only. Production Firestore received read-only diagnostic reads before the project mismatch was fixed; no production data was changed. Production R2, Firebase Storage, deployed Workers, deployed Functions, and paid cloud resources were not used or changed.

## Physical Role Recognition Follow-up — 2026-11-16

### Root cause

The debug Android manifest allowed Firebase's native `FirebaseInitProvider` to initialize the default production-configured Firebase app before Dart bootstrap ran. The app's emulator configuration then reused that native default app instead of creating and verifying the emulator project. After the initialization fix, a second physical-device constraint became clear: FlutterFire's Android emulator helper maps a loopback hostname (`127.0.0.1`) to `10.0.2.2`. That address works on the Pixel emulator but not on a physical handset. The Firestore request could not reach the emulator, and old application state handling silently mapped the missing profile to `customer`.

### Changes and evidence

- Debug-only `AndroidManifest.xml` removes FirebaseInitProvider; release initialization remains unchanged.
- Emulator bootstrap creates and verifies the expected `demo-localspot` app. A configurable `FIREBASE_EMULATOR_HOST` supports using the development host's reachable LAN address on a physical phone. Local-only analytics, Crashlytics, and App Check are disabled for the emulator build.
- Profile loading now distinguishes loading, loaded, customer, owner, admin, unavailable, failed, and signed-out states. A missing role/profile or Firestore failure no longer silently grants the customer default. Stale profile state is guarded during account changes.
- On the phone, logs now show `project=demo-localspot`, server-sourced `users/{authUid}` lookup with UID-match boolean, and `role=owner`; owner store tools and tour editor work. Customer, admin, missing-profile, sign-out/sign-in, and restart scenarios passed in earlier physical checks. Firestore failure injection was not conclusively exercised.
- Added three role/profile state tests. Combined with app smoke tests, the focused run passed 25 tests; `flutter analyze lib test` reported no issues.
- Physical panorama encoding then revealed that the copied JNI method exported the standalone prototype package name. The symbol was corrected to the integrated package's JNI-escaped name and the rebuilt APK generated a full-dimension derivative successfully.
- A real seam-adjacent manual mask was added and moved. Changing it invalidated the prior derivative/review. Regeneration completed from the current correction set and cleared the stale warning; the resulting digest was displayed on the handset. The 360° review page then opened at 0/48. It was left incomplete to avoid attesting on the owner's behalf.

The initial diagnostic app build reached the production-configured Firestore project for reads only. After the fix, all physical app calls for these scenarios were made to `demo-localspot` through `192.168.1.58`. No production write, deployment, or live R2 request occurred.

## Final Physical Workflow Follow-up — 2026-11-16

### Current verification

- Rebuilt debug app remains configured with explicit emulator opt-in and the `demo-localspot` project. `lib/firebase/bootstrap.dart` now fails closed if debug emulator selection/host is missing, rejects emulator use in release, verifies the emulator project ID, and checks the production app ID on release. The debug manifest provider removal remains scoped to `src/debug`.
- Firebase emulator and Wrangler listeners were present on ports 9099, 8080, 5001, and 8787. The local Worker `.dev.vars` project identifier equals `demo-localspot`; Auth emulator URL and public gateway JWKS are configured (secret values were not printed). `GET /health` returns 404 because no health route is defined; this did not exercise R2.
- Admin SDK read of only the local `demo-localspot` quota document returned the 9,000,000,000-byte limit, zero used bytes, zero reserved bytes, `uploadEnabled: true`, `reconciliationState: completed`, and no maintenance lock. This is emulator state, not production reconciliation. A prior local reconciliation inventory is recorded above as zero objects/bytes.
- Physical owner role/profile resolution and tour editor access remain passed, with earlier handset logs showing the project and profile source. No new production calls were made.
- The Wikimania derivative was regenerated after restoring the persisted single seam-adjacent mask. The screen showed 6528×3264, 2,190,799 bytes, digest `7c6f69cdc09899c8ca6f686cdf89119586cfaabad1abbb4621a6168aa51e8f54`, and 303 face/73 person detections. This confirms output generation and review invalidation behavior, not detector accuracy or privacy completeness.
- Manual mask addition, movement, deletion, undo/redo, force-stop/restart persistence, seam-adjacent placement, derivative regeneration, and stale-review invalidation are physically evidenced across this and the prior role follow-up. During this follow-up, adding then deleting a second mask restored the single saved mask. Repeated resize gestures did not change its `21.6° × 21.6°` span; physical resize therefore remains **unverified**. Physical poles and quantitative spherical-view alignment were also not independently validated.
- The 360° review screen opened at 0/48. Marking the already presented first direction advanced to 1/48 and displayed the next checkpoint. This verifies one presented-direction transition. The remaining directions, acknowledgements, authenticated review submission, and edit-after-review reset were **not completed**. No owner attestation was submitted.
- Focused Flutter test run: **29 passed** (bootstrap configuration, profile/role, and application smoke tests). `flutter analyze lib test`: **clean**. Functions `npm run build`: **passed**. Worker `npm test`: **16 passed**; `npx tsc --noEmit`: **passed**. Worker tests use mocked R2.

### End-to-end workflow outcome

**Not completed.** No original or derivative was uploaded in this follow-up, no stored-object metadata or backend SHA-256 was verified against a real local R2 binding object, no quota finalization followed an actual uploaded file, no review was submitted, no publication occurred, and no private/public media fetch was exercised. The current test device was stopped at 1/48 review coverage. Do not interpret the emulator quota document's enabled flag as a completed upload-path test.

One concrete physical-local configuration blocker was identified: `functions/.env.demo-localspot` currently sets `R2_GATEWAY_URL=http://127.0.0.1:8787`. A URL returned by Functions to the physical Infinix using that host points back to the phone itself, not the development PC. The app's Auth/Firestore/Functions emulator host is the PC LAN address `192.168.1.58`; the gateway URL must be changed to a phone-reachable local Worker address and the Functions emulator restarted before physical uploads can work. This local environment file was not changed during the validation.

### Remaining validation blockers

1. Fix and verify the physical-device Worker URL, then confirm upload requests reach only Wrangler local storage.
2. Complete physical resize, polar placement, seam projection, and 360° alignment checks. The attempted resize gesture did not change the mask span.
3. Complete and inspect all 48 review checkpoints, then test explicit acknowledgements, authenticated UID binding, submission, and review invalidation. One checkpoint only was recorded locally; no review was saved.
4. Exercise the actual integrated upload/verify/finalize/review/publish/download path against the local Worker R2 binding and Firebase emulators, including failure/retry and security cases from the request. Existing callable and Worker tests do not substitute for this integrated path.
5. Test two eligible panorama viewpoints if publication requires multiple nodes, plus public derivative delivery and private-original retrieval, while proving the original remains unreachable through public routes.
6. Reconcile the actual production R2 bucket and its Firestore quota ledger before any production upload is enabled. No production reconciliation, R2 upload, Firestore write, or deployment was performed.

## Updated readiness decision

Local source checks and emulator isolation checks are green, but physical end-to-end and local R2 end-to-end validation are **incomplete**. Production deployment and production media cutover remain blocked. No real Cloudflare R2 request has been made.
