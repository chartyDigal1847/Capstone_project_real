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

### Follow-up validation — 2026-11-16

- Added explicit debug-only `FIREBASE_AUTH_EMULATOR_PORT` and `FIRESTORE_EMULATOR_PORT` overrides (defaults remain 9099 and 8080) so an isolated LAN-bound emulator pair can be used by a physical device without disturbing the existing loopback emulators.
- On the Infinix X6873, installed a debug build targeting only `demo-localspot`, LAN-bound Auth/Firestore emulators, the local API Worker, and the local R2 test mode. Registration succeeded; Worker profile bootstrap returned 200; Firestore server profile read resolved the account as `customer`. Selecting the owner role in the registration form did not elevate the profile. Customer Profile now exposes the existing store-application form.
- Called the Worker store-application endpoint with the emulator-authenticated account; it returned `pending` and wrote an owner-bound application. The test document was removed afterward.
- Exercised the media API and local upload gateway against Wrangler's persistent local R2 simulation using a small repository JPEG: reservation, upload (201), server finalization (`ready`), and verified deletion all succeeded. The temporary upload records were removed and the demo quota was reset to `usedBytes=0`, `reservedBytes=0`. This flow was driven from the development host and is not evidence of a phone-originated file upload or panorama review/publication.
- Panorama processing, the 48-checkpoint review, derivative reservation/finalization from the app, publication, private/public fetch, and authorization edge cases remain outstanding on-device. Production R2 and live service checks remain unperformed.

### Physical follow-up — 2026-11-16 (local Worker route and processing)

- Replaced the previously mismatched ignored gateway dev JWKS with a newly generated local-only ES256 keypair. The gateway's public JWKS and API Worker's private JWK now match; neither key was printed or added to tracked source. Both local Workers use Wrangler's local `localspot-backend-local` R2 simulation and LAN-bound emulator endpoints. No Cloudflare deployment or remote bucket was used.
- Started separate Auth/Firestore emulators on LAN ports 19099/18080. A debug APK connected to `demo-localspot`, `http://192.168.1.58:8788` (API Worker), and `http://192.168.1.58:8787` (local upload gateway). App logs confirmed the configured emulator project and server-loaded profile.
- Registered `panotest20261116@localspot.invalid` on the Infinix. Choosing “Store owner” during sign-up still produced a customer profile, confirming the requested role was not trusted. For this isolated workflow only, the emulator profile was then elevated using the Admin SDK and an approved test store was seeded; Firestore rules were not changed.
- Created a draft tour for the test store from the device through the Worker-backed tour route and opened the panorama picker. The device selected `6039.jpg` (the staged Wikimania panorama). On-device privacy processing completed: 6528×3264 derivative, 2,219,329 bytes, 303 face detections, 73 person detections, 376 total blur regions, 12,257 ms, derivative SHA-256 `ed45db614aee2ab9eeed982bd16841948aee1230f91d404132c969c3b26472f7`.
- **Stopped at owner review.** No 48-direction attestation was submitted, no original or derivative was uploaded from the phone, and no publication or private/public retrieval occurred. The app remains at the physical panorama review screen so the owner can conduct the required visual inspection. Local emulator and Worker processes remain running for that review; they are temporary and must be stopped after the session.

### Completed physical panorama workflow and local R2 reconciliation — 2026-11-17

This follow-up supersedes the earlier “Not completed” outcome above. The owner inspected the panorama in the app and explicitly confirmed it was acceptable; the app recorded all 48 review directions and both required acknowledgements before upload.

- The Infinix X6873 completed on-device panorama privacy processing, owner review submission, upload, backend verification, quota finalization, tour-node update, and retrieval of both the private original and verified derivative. Upload/finalization/review responses were successful. The original was 11,690,366 bytes; the backend verified derivative was 2,119,189 bytes with SHA-256 539136ecde38e3c00887d78e4f71b7017ca730b4bdd5b13a01e9df152aaa7400.
- Both objects were written through the LAN-bound local Workers to Wrangler's persistent local R2 simulation. No live Cloudflare R2 or production Firebase service was used. Owner-only original retrieval succeeded; unauthenticated private retrieval returned 401, and attempting the private original via the public media route returned 404.
- Publishing was attempted and correctly rejected with HTTP 412 because the draft contains only one reviewed viewpoint. No publication occurred; a second independently processed and reviewed viewpoint is still required to meet the publication gate.
- The backend integration suite had previously been run against this physical test emulator and left quota-test fixtures behind. The fixtures were checked against their exact test-only fields and removed; the fake public object was confirmed absent from local R2 (404). The Worker then performed a fresh inventory reconciliation: completed, 2 objects, 13,809,555 actual/used bytes, 0 reserved bytes, 0 pending reservations, 0 missing objects, 0 orphaned objects, and 0 size mismatches. Final emulator quota state is uploadEnabled=true, maintenanceLock=false. The test account role was restored to owner.
- Typechecks and suites previously run for this migration passed: backend Worker 38/38 (7 files), gateway Worker 18/18. Do not rerun emulator integration tests against the physical workflow emulator; those tests seed emulator-only fixtures. Use a separate isolated Auth/Firestore emulator instance for any repeat run.
- Local-only Worker validation accepts the private LAN address only when emulator mode is enabled; production gateway URLs continue to require HTTPS. No deployment, production write, or production media cutover was performed.

Readiness: the physical single-viewpoint upload/review/private-access flow and local R2 accounting are now verified. Production deployment and cutover remain unvalidated and were not performed. Public delivery after publication and a multi-viewpoint publish flow remain unverified.

### Second viewpoint prepared for owner inspection — 2026-11-17

The 35C3 sample fixture was staged on the Infinix and processed locally. The review screen is open on the device for the owner to inspect. No second-viewpoint attestation or upload has been submitted.

- Source fixture SHA-256: 5af25da7706ce6dad1b67dbcec01953a44811a386ce5cf7d12daf1cc5c557a3e. Derivative: 18,000×9,000, 22,132,765 bytes, SHA-256 b63ec7631a408c98873f4bf976f3d2f36d4c045e351534db36298837f5a503a9; processing took 47,496 ms and reported 0 face detections, 4 person detections, and 4 total blur regions. These are detector counts, not a privacy guarantee.
- The review requires visual inspection of the full sphere and all 48 directions, including any missed people. Keep publication gated until the owner finishes that review and submits the attestation, then upload/finalize and verify the second derivative.

### Second viewpoint verified and local two-view publication completed — 2026-11-17

After the owner approved the second derivative in the app, the device submitted the 48-direction review with both acknowledgements. The app uploaded the original and processed derivative, created Viewpoint 2 connected to Viewpoint 1, and reported backend verification, quota finalization, and owner attestation success.

- The second original is 12,563,809 bytes. Its backend-verified derivative is 22,132,765 bytes, SHA-256 b63ec7631a408c98873f4bf976f3d2f36d4c045e351534db36298837f5a503a9. The local tour has two viewpoints, each with a current backend-verified derivative and owner review containing directions 0–47 and both acknowledgements.
- The owner published the draft through the app to the local emulator. The tour status is published. For each viewpoint, the authenticated published-access route returned a signed gateway capability; media GET returned 200 and downloaded bytes matched the derivative’s SHA-256. Requests without a gateway capability returned 401. The second private original via the public media route returned 404.
- Final local Worker reconciliation completed with 4 objects totaling 48,506,129 bytes, 0 pending reservations, 0 missing objects, 0 orphaned objects, and 0 size mismatches. Firestore quota is 48,506,129 used, 0 reserved, upload enabled, and maintenance lock cleared. The test profile was restored to owner.
- This validates two-viewpoint publication and signed delivery against local emulators and Wrangler's local R2 simulation only. Nothing was deployed or published to production.

### Additional physical owner inventory workflow — 2026-11-17

- On the same Infinix X6873 local-emulator session, the owner created a manual `MangoLocalQA` listing through the Worker-backed Add Product screen with price PHP 10, unit `piece`, and starting quantity 10. The app returned to the owner dashboard showing one active listing; Inventory displayed the same confirmed listing.
- The Restock action increased quantity from 10 to 15. The Archive action presented a confirmation identifying the listing and warning that customers would no longer see it; after confirmation, the active inventory was empty. This exercised safe archival, not hard deletion.
- No product photo was attached, so physical product-media upload and catalog image delivery remain unverified. This was emulator data only; no live Firebase or Cloudflare services were contacted.
- The owner also submitted a `LocalQAOffer` promotion with the sponsored-placement request enabled. The app displayed it in the owner list as `pending`, confirming the Worker-backed submission route; admin approval and customer-side sponsored-card display were not exercised. The pending record remains in local emulator data for review/testing.

### Customer browse, search, filters, and map preview — 2026-11-17

- Registered and signed in a second emulator-only customer account (`browseqa@localspot.invalid`) on the Infinix. The customer Home screen loaded sponsored and nearby-store sections; after switching the search area to the approximate Cubao fix, the customer Search screen returned two active `LocalBrowseQA` listings at PHP 25 per piece and 0.1 km. The category filter was set to Groceries and a PHP 20 minimum price filter applied; both listings remained. The app status text identifies this as a direct Firebase catalog query, consistent with Firestore remaining the client catalog source.
- The Map screen rendered its in-app preview with location and seller pins, and the app requested foreground location permission. The permission was granted for this device test; Profile states foreground-only use and no background tracking. Mapbox is not configured in this debug build, so production street tiles, geocoding/routing, and navigation remain unverified. No Mapbox token or paid mapping service was used.
- Two same-name active QA listings are currently visible in the local test catalog; they were created while preparing browse data. Archive them after customer-side inspection. This test account's approximate-area setting and foreground permission are local device state.

- Follow-up cleanup: both LocalBrowseQA inventory records were confirmed archived on-device; owner Inventory is empty. No hard deletion was used.

### Account deletion cleanup hardening — 2026-11-17

- Code review found account deletion removed panorama originals but did not include immutable derivative revisions stored in `mediaAssets/{uid_asset}/derivatives`. The Worker and retained Firebase Function fallback now delete those derivative R2 objects through the quota ledger and mark their revision records deleted. The Worker paginates the derivative subcollection so later revisions are included.
- Focused tests passed for user-prefix filtering and multi-page Firestore subcollection traversal. The complete backend Worker suite passed 43/43 tests across nine files against a separate Auth/Firestore emulator pair. The account-deletion integration case exercised the Worker against emulator Auth/Firestore with an in-memory R2 gateway mock, confirming both derivative revisions were removed and all three object sizes were released from the quota ledger. A new regression test verifies media deletion re-reads linked state inside the transaction before claiming deletion. Both the Worker and retained Firebase Function fallback now use that transactional deletion claim; Worker and Functions TypeScript checks passed. This does not replace a test against Wrangler's local R2 binding, and the account deletion flow was not rerun against the physical emulator in this pass.

### Mapbox token wiring and physical street map — 2026-11-17

- Removed the public token fallback from tracked Dart source. The locally copied `pk.` token now lives in ignored `config/local.json`; Flutter receives it through `--dart-define-from-file=config/local.json`. `main.dart` already initializes the Mapbox SDK from `mapbox_config.dart`, so no token literal was added to the entry point. README local-run instructions now use the ignored config file.
- Rebuilt and launched the debug app on the Infinix X6873 with `demo-localspot`, local Auth/Firestore emulators, and the local Worker endpoint. The customer Map screen rendered Mapbox Streets with readable roads/labels, scale bar, Mapbox logo/attribution, nearby map pins, and the foreground-only location notice. This supersedes the earlier missing-token preview result for the current local build.
- Map rendering is now physically verified with the copied public token. Directions API routing, geocoding, satellite style, billing/usage limits, and production token restrictions remain unverified. No deployment or production service access occurred.

- Additional physical Mapbox checks: selecting the local emulator store opened its details over Mapbox Streets. “Preview route in LocalSpot” reached the Mapbox Directions API and displayed a 0.1 km, 1 minute driving route with an in-app route polyline. “Start in-app navigation” opened the foreground position-following map screen; UI states turn-by-turn voice guidance is not included. Position-following was stopped after the check. The manual approximate Cubao search-area setting was used to reach the local store; route result is local test data and should not be interpreted as a real navigation trip.

### Physical product media upload check — 2026-11-17

- On the Infinix X6873, the owner added `LocalSpot mango QA` at PHP 25 per piece with quantity 10. The listing appeared in owner Inventory and then in customer Search, where its thumbnail loaded from the local catalog/media route. This confirms the handset completed the product-image reservation/upload/finalization path and the customer client fetched the resulting image.
- The picker selected a recent app screenshot rather than the synthetic fruit image staged for this test. Therefore this verifies media transport and delivery, but not fruit-photo content, image appearance, or metadata handling. The listing remains local emulator QA data pending owner-side archival; the app session was signed out before cleanup. No production Firebase or Cloudflare service was contacted.

### Physical account deletion check — 2026-11-17

- Registered a fresh throwaway customer account on the Infinix X6873 against the local Firebase Auth/Firestore emulators and initiated account deletion from Profile. The app returned to the welcome screen. A follow-up sign-in request to the local Auth emulator returned `EMAIL_NOT_FOUND`, confirming that the Worker-backed flow removed the Auth account.
- This was an emulator-only test account; no existing test user or production account was changed. Related-data cleanup remains covered by Worker tests; a production Firebase account deletion was not attempted.
- The account-deletion implementation also exposed a Worker bootstrap gap during subsequent isolated testing: emulator Auth identity lookup returned email/display name, but the Worker dropped those claims, producing blank profile email/default names. The adapter now preserves those verified emulator fields, and registration passes the chosen name to bootstrap. A dedicated isolated emulator regression test asserts these profile fields and the customer-only role.
- Repeating the Worker integration suite against a second, isolated Auth/Firestore emulator revealed intermittent Firestore `409 Transaction lock timeout` failures during concurrent quota reservations. `FirestoreRest.runTransaction` now retries those transient lock/contention conflicts with bounded jittered backoff, alongside `ABORTED`. The dedicated race case and full 38-test Worker suite pass against the isolated emulator pair; no active physical-workflow emulator fixtures were touched by that run.

### Pixel 9 emulator customer startup and search — 2026-11-17

- Installed the debug build on a Pixel 9 API 35 emulator pointed at a separate `demo-localspot` Auth/Firestore emulator pair and Wrangler's local backend Worker/R2 simulation. Registered a disposable customer account through the app; registration completed into the customer Home screen, which displayed the Firebase-connected empty-catalog state. The Search screen opened and rendered its filters and empty results state (`0 participating listings within 3 km`).
- This confirms registration/bootstrap and customer search UI startup on a second emulator. The isolated Firestore dataset had no catalog listings, so result rendering with records, filtering, and map flows were not verified on this device. This is not a physical second-device run. No production Firebase or Cloudflare services were contacted.
