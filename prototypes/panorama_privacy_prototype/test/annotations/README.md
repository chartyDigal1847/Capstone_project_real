# Panorama detector ground-truth protocol

The two public sample panoramas are fixtures, not a statistically representative privacy benchmark. Do not report detector accuracy from detection counts alone.

## Annotation procedure

1. Record the fixture's SHA-256, dimensions, annotator, annotation date, and tool/version. Use an offline image annotator that can display the complete equirectangular image at full resolution. Hide all detector overlays and results while annotating.
2. Draw one tight box around every visible person's full visible body and a separate box around each visible face. Include partially occluded people when a human annotator can identify them as a person. Mark ambiguous examples as `uncertain` and exclude them from primary metrics while reporting the count.
3. Tag each instance with any applicable strata: `small`, `distant`, `occluded`, `crowded`, `seam`, `north_pole`, `south_pole`. A seam object appears across both image edges; annotate it once using a box with `wraps_seam: true` and normalized x origin/width. For pole instances, annotate the visible body/face extent at the respective top or bottom edge.
4. Have a second annotator independently label the same fixtures without seeing the first annotations. Resolve disagreements and retain both raw label sets plus a consensus set. Keep a held-out panorama set for any threshold changes.
5. Export the detector's raw unmerged face/person boxes and the mapped spherical regions. Use one-to-one maximum-IoU matching at IoU >= 0.5 separately for faces and people. Report precision, recall, F1, missed-instance counts, false positives, and duplicate predicted regions (extra predictions assigned to already matched ground truth), overall and per stratum. Also inspect overlays manually at both seams and poles. Do not count a broad merged blur mask as multiple detections.

## Annotation file

Use `ground_truth.template.json` as the schema example. Coordinates are normalized to `[0,1]` in the source equirectangular image. `x + width > 1` is permitted only when `wraps_seam` is true. Boxes touching a pole use `y = 0` or `y + height = 1` respectively.

No ground-truth labels are included yet; consequently this prototype currently has no measured miss/false-positive accuracy results.
