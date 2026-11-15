# On-device panorama privacy prototype

This is an isolated Android/Flutter prototype. It does not change the LocalSpot production Flutter app, Firebase Functions, Firestore, R2, or deployment configuration. The prototype targets Android API 24+ because its current image picker dependency declares that minimum; production integration can use the platform document picker if LocalSpot must retain a lower minimum SDK.

## What it exercises

- Bundled ML Kit face detector (`com.google.mlkit:face-detection`), so the face model is present at install and inference does not depend on model downloads.
- Bundled MediaPipe Tasks Object Detector plus the EfficientDet-Lite0 INT8 COCO model (`person` class).
- Four azimuths at three elevations plus zenith/nadir perspective views; each uses a 100° field of view. Detections map back to spherical coordinates and expanded regions are mosaicked locally.
- A dedicated 360° owner review route showing only the processed derivative. Owners can drag freely, jump among 48 spherical checkpoints (8 longitudes × 6 latitudes, including seam-adjacent and polar-cap viewpoints), and explicitly mark each presented direction. The tracker records review actions; it cannot prove that every person was noticed.
- A full equirectangular manual correction map with add, move, resize, remove, undo, redo, local persistence, and regeneration from the original. Owners can pause review to edit; regenerating resets coverage and requires review of the new derivative.
- Final local review requires all 48 checkpoints, a present derivative whose SHA-256 is rechecked, idle processing, acknowledgement that automatic detection can miss people, and confirmation of manual inspection. An authenticated host adapter supplies the UID when present; without one, the model stores `local-prototype-review` with no invented UID. Neither record is production approval and nothing can publish from this prototype.

## Run

From this directory:

```powershell
flutter pub get
flutter run
```

Choose an equirectangular JPEG with a 2:1 aspect ratio and press **Detect and blur on device**. Detection uses a separate image sampled to at most 4096 pixels wide. The derivative writer streams source scanlines and preserves full input dimensions; it does not decode a full-resolution panorama bitmap or create a full-size blur bitmap. It uses a 32 MiB libjpeg virtual-array RAM budget and private unlinked cache files for excess progressive-JPEG coefficients. Before processing, the app checks for approximately six bytes of free scratch space per source pixel plus 64 MiB. The source remains untouched. Manual corrections use spherical coordinates, persist locally by source digest, and regenerate a derivative from the original.

The streaming path currently accepts JPEG only and rejects EXIF-rotated inputs. Output is a JPEG at quality 92. Masked areas use a 24×24-pixel mosaic in source coordinates; this is deliberately visible and does not guarantee every person was detected. Cache files are private to this app, are unlinked while open, and are released when processing finishes. A storage shortage or decoder/encoder failure fails the operation; it never reports a successful derivative.

Run the Flutter checks with `flutter analyze` and `flutter test`. Run native geometry tests from `android` with `./gradlew app:testDebugUnitTest`. See [FUTURE_IMPROVEMENTS.md](FUTURE_IMPROVEMENTS.md) for prioritized blockers and later improvements.

## Full-resolution physical-device run (Infinix X6873, Android 16/API 36/arm64)

The fixture picker showed each source filename, dimensions and SHA-256 before processing:

| Fixture | Source | Full-resolution output | Processing | Sampled PSS | Result |
|---|---:|---:|---:|---:|---|
| Wikimania 2023 | 6528×3264, 11,690,366 B | 6528×3264 JPEG, 2,203,821 B latest | 12.227 s in later physical run (11.891 s earlier) | about 390–472 MiB during the later run | 303 face + 73 person detections; saved manual masks were applied |
| 35C3 | 18000×9000, 12,563,809 B | 18000×9000 JPEG, 22,132,765 B | 47.968 s final run | 401–417 MiB during writing; 381 MiB immediately after preview recycle | 0 face + 4 person detections |

The fixture selector verified Wikimania SHA-256 `c2ea88d1d01543ce4123235bb1fd39bd28498dc5458cb7d519e50e112b2f0315` and 35C3 SHA-256 `5af25da7706ce6dad1b67dbcec01953a44811a386ce5cf7d12daf1cc5c557a3e`; attribution is in `../../test/fixtures/panorama_privacy/ATTRIBUTION.md`. A previous in-memory progressive-JPEG run sampled around 1.42 GiB PSS during the write and around 1.43 GiB while displaying the result. The final disk-backed 35C3 run sampled 401–417 MiB during scanline writing and 381 MiB immediately after preview recycling. App PSS is sampled through Android `Debug.MemoryInfo`; it is not a continuous profiler maximum. During Wikimania correction runs, PSS peaked around 472 MiB while decoding the preview, then fell to 450 MiB after the preview bitmap was recycled. On-device displayed-result samples ranged around 435 MiB in a separate `dumpsys meminfo` snapshot. No run crashed or reported OOM. Battery temperature readings were 37.9–38.4°C; the battery sensor is not a direct SoC temperature measurement. CPU utilization was not captured, so no CPU percentage is claimed.

## 360° owner-review physical walkthrough (Infinix X6873)

On the physical device, the Wikimania fixture was loaded through the debug-only fixture picker and verified as 6528×3264 with SHA-256 `c2ea88d1d01543ce4123235bb1fd39bd28498dc5458cb7d519e50e112b2f0315`. Processing completed in 12.285 seconds and generated a 6528×3264, 2,203,821-byte derivative. The review route displayed that processed derivative. The initial checkpoint did not count until its view was presented and explicitly marked.

The device completed the sequential 48/48 checkpoint route, including both polar-cap rows and the left/right seam-adjacent viewpoints. The final screen showed 48 green inspected indicators. The first acknowledgement alone kept final approval disabled; after both acknowledgements, local approval saved and displayed a timestamp, derivative digest, and `localspot-panorama-local-v2`. No authenticated UID was configured, so the record was labeled local prototype review.

From review, the owner opened the manual editor, added a spherical correction, regenerated from the original, and returned automatically to the 360° viewer. Coverage reset to 0/48 for the regenerated derivative. This confirms the workflow on one device and fixture; it does not establish privacy guarantees or broad usability. The captured 48/48 screen is [review-48.png](review-48.png).

The final 35C3 output took about 2.2 seconds longer than the previous 45.772-second full-resolution writer run, while peak sampled PSS decreased by roughly 1 GiB. This tradeoff is specific to this device and fixture. Actual backing-file peak size was not instrumented. The scratch-space check is conservative, but successful processing on two fixtures is not a proof of memory or storage safety for every Android device or JPEG.

The full-resolution output images are local test artifacts in this prototype folder: `wikimania-full-final.jpg` and `35c3-full-final.jpg`. Their displayed side-by-side comparisons are `comparison-wikimania.jpg` and `comparison-35c3.jpg` (original on the left, processed output on the right). Dimensions were confirmed by the app and successful preview decode. The images retain unmasked source content and must not be published without full human review.

## Ground-truth evaluation

`test/annotations/README.md` documents the blind annotation and scoring procedure; `ground_truth.template.json` is the schema. No annotated ground truth exists yet, so there are no measured recall, precision, missed-person, missed-face or false-positive results. Detector totals are not accuracy measurements.

Physical editor checks covered adding a seam-crossing mask, moving and resizing a spherical mask, removal, undo/redo, local persistence after relaunch, corrections at the north and south pole edges, and regenerating from the original. The persisted seam mask wraps from longitude 174.9° across 180° and is drawn in both edge segments. One correction began at the north edge (`y=0`), and another ended at the south edge (`y+h=1`); both temporary pole checks were undone. The saved spherical mask spans and row readouts changed during physical drags. This remains a small manual check, not a comprehensive touchscreen usability study.

## Release artifacts

Built with bundled models intact after the latest source changes:

| Artifact | Architectures | Exact bytes |
|---|---|---:|
| `build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk` | 32-bit ARM | 37,311,123 |
| `build/app/outputs/flutter-apk/app-arm64-v8a-release.apk` | 64-bit ARM | 46,424,765 |
| `build/app/outputs/flutter-apk/app-x86_64-release.apk` | 64-bit x86 | 51,751,760 |
| `build/app/outputs/bundle/release/app-release.aab` | App Bundle; Play can serve supported splits | 97,381,680 |

After the owner-review changes, `flutter test` passed all 15 tests, `flutter analyze` reported no errors (style infos remain), and Android `:app:testDebugUnitTest` passed. Earlier prototype release artifacts use the debug signing key; they are not production-signed or deployed.

## Model and fixture notices

- The MediaPipe Tasks library and EfficientDet-Lite0 model are Apache-2.0 licensed. The model is the official COCO-trained INT8 EfficientDet-Lite0 artifact (4,602,795 bytes). Preserve applicable `LICENSE` and third-party notices when distributing.
- Bundled ML Kit face detection adds approximately 6.9 MB according to Google's Android guide; the selected bundled dependency is `com.google.mlkit:face-detection:16.1.7`.
- Real panorama fixtures are outside this prototype APK under `../../test/fixtures/panorama_privacy/`; see its `ATTRIBUTION.md`. They are for local testing only and must not be uploaded to R2.

## Not production-ready

The detector may miss small, distant, occluded, back-facing, unusual, or distorted people. Face and person findings from overlapping views are not optimally deduplicated. The owner must inspect the sphere and manually correct missed people; review is not a guarantee. The 48 checkpoints record explicit interactions only and cannot prove that every person was noticed. Annotation-based accuracy metrics are not available. CPU usage, continuous PSS peaks, and maximum scratch-file use are not established. JPEG is the supported input; other formats and EXIF orientation handling are incomplete. Local review is not connected to Firebase Authentication and is never trusted production approval. The prototype does not upload derivatives, verify R2 object bytes, persist production processing metadata, authorize original access, finalize production quota, or publish tours. Backend verification and authorization are required before publication; a digest proves bytes and identity, not privacy quality.
