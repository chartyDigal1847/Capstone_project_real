# Panorama Privacy Prototype — Future Improvements

This register describes known limits as of the isolated prototype review flow. It is a planning document, not a claim that listed work is complete. **No production Firebase, Firestore, or R2 integration is included here.** The local approval record cannot authorize publication.

## Required before production release

| # | Current limitation | Why it matters | Recommended improvement | Priority |
|---|---|---|---|---|
| 1 | Detection can miss small, distant, occluded, distorted, back-facing, or crowded-scene people. | An unmarked person can remain identifiable in the derivative. | Keep explicit owner review and manual correction; broaden evaluation panoramas and improve detection only against measured failures. Never describe automated detection as a privacy guarantee. | High |
| 2 | Detection has not been evaluated against manually annotated ground truth. | Detector totals cannot establish recall or privacy effectiveness. | Annotate fixture panoramas independently and report per-person/per-face recall with an agreed matching threshold. | High |
| 3 | False-positive, missed-detection, and duplicate-region rates are unknown. | Excess false positives reduce usability; misses expose people; duplicates can obscure too much. | Score precision, recall, duplicate rate, and region overlap against annotations before selecting thresholds or claiming accuracy. | High |
| 4 | Overlapping detection regions are not optimally merged. | Duplicates can increase over-blurring and complicate owner edits. | Add spherical IoU/connected-region merging, preserve seam wrapping, and verify against hand-reviewed masks. | Medium |
| 5 | CPU usage has not been measured with a reliable processing-time profiler. | Battery and thermal impact across Android devices is unknown. | Profile representative low, mid, and high tier physical devices with sustained CPU/thermal metrics. | Medium |
| 6 | PSS has been sampled, not captured as a continuous profiler maximum. | A short-lived memory spike may have been missed. | Run Android Studio/Perfetto memory traces for processing and viewer display on constrained devices. | Medium |
| 7 | Maximum temporary scratch-file use has not been established. | Large images may exhaust device storage even when RAM is bounded. | Instrument peak scratch usage and test low-storage, cancellation, and process-death cleanup cases on multiple devices. | High |
| 8 | The streaming path accepts JPEG; other formats and EXIF orientation behavior are incomplete. | Users may select images that cannot be safely or correctly processed. | Add explicit format support with orientation normalization, or keep the picker constrained to supported JPEGs and show a clear rejection reason. | Medium |
| 9 | Original-retention and re-edit policy is not implemented in production. | Originals contain unblurred people and need a deliberate privacy and recovery lifecycle. | Define private-only original retention, access auditing, retention deadline, owner re-edit process, deletion confirmation, and backend cleanup before R2 integration. | High |
| 10 | Firebase Authentication is not connected to the local review model. | The prototype cannot establish who reviewed or approved an image. | Adapt the host's authenticated UID in a production review service; backend must bind it to the authorized owner and derivative digest. | High |
| 11 | R2 upload, backend object verification, SHA-256 calculation, and quota finalization are not connected. | Local files and client metadata cannot establish what is stored or counted. | Integrate via the existing secure upload reservation/gateway, verify stored bytes and metadata server-side, calculate the digest in trusted backend code, then finalize the existing 9,000,000,000-byte transactional quota. | High |
| 12 | Production publication authorization is not implemented. | A client-side approval flag must never make an object public. | Require backend checks for authorized owner, current verified derivative digest, complete persistent review, publication eligibility, and approved media route. | High |
| 13 | The 48-direction tracker records explicit owner actions but cannot prove that a person was noticed. | A completed count is a checklist, not evidence of visual attention or privacy. | Retain clear disclosures, make uninspected areas easy to revisit, and require human inspection; do not use the count as a privacy guarantee. | High |
| 14 | Real privacy effectiveness still needs more varied panoramas and manual inspection. | Two fixture scenes cannot represent varied lighting, camera placement, crowd density, or projection artifacts. | Build a diverse, consented test corpus and repeat ground-truth annotation plus human review across scene types. | High |

### Production release gate

Items 1–3 and 5–8, 10–14 need a documented mitigation or completion decision before release. In particular, production must not rely on client-supplied processing status, a digest alone, or the local 48-direction record as proof of privacy. Item 4 can be staged after initial release if manual review remains mandatory and false positives are handled safely; its expected impact should still be evaluated before launch. No release decision is implied by this prototype.

## Improvements that can follow an initial release

| Improvement | Current limitation | Why it matters | Recommended improvement | Priority |
|---|---|---|---|---|
| Spherical duplicate-region merging | Overlapping model outputs remain separate regions. | Better merge behavior can reduce editor clutter and excess blur. | Implement after baseline ground-truth scoring; preserve separate source labels for debugging. | Medium |
| Broader device profiling | Current measurements cover the Infinix X6873 only and use sampled PSS. | User devices vary in memory, thermal behavior, and hardware acceleration. | Maintain a device matrix and repeat automated profiling on OS/model updates. | Medium |
| Additional image formats | JPEG is the currently supported processing input. | Some camera and editing workflows produce HEIC, PNG, or rotated JPEGs. | Add format adapters only with orientation and full-resolution quality tests. | Low |
| Owner-review analytics | The local tracker records actions only. | Product teams may want to find review UX points where owners get stuck. | Consider privacy-preserving aggregate UX telemetry after consent and policy review; never record panorama imagery in telemetry. | Low |

## Current physical-device evidence

The Infinix X6873 (Android 16/API 36, arm64) produced full-resolution JPEG derivatives for the two available fixtures without a crash or reported OOM. The 35C3 run completed in about 47.968 seconds and sampled 401–417 MiB PSS during scanline writing. These are fixture-specific observations, not upper bounds. CPU utilization and continuous peak memory have not been captured reliably. No ground-truth annotations currently exist.
