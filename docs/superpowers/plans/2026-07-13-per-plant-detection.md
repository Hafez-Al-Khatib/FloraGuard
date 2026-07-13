# Per-Plant Bounding-Box Detection Implementation Plan (Sub-project B)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Detect and box each plant/leaf in a camera frame and diagnose each one, so one camera covering multiple plants gives a per-plant diagnosis — not a single whole-frame label.

**Architecture:** A dedicated object **detector** (YOLO), NOT the whole-frame classifier. It localizes + classifies each region. Each box's class collapses to the reliable coarse group and (with the node's crop) a specific disease, reusing `COARSE_GROUPS`/`CROP_OF`. Boxes flow through a new detection-list storage, SSE, treatments-per-group, and a `BoxOverlayPainter` UI on both dashboard and app.

**Tech Stack:** Ultralytics YOLO (v8n/v11n) trained on PlantDoc's bounding boxes → ONNX; onnxruntime in the FastAPI edge; Flutter CustomPainter for overlays; the existing group/crop/treatment stack.

## Global Constraints
- **Accuracy gate (non-negotiable):** the per-plant diagnosis must NOT be the weak 44% classifier. Deployment is gated on **group-level mAP@50 ≥ 0.55** and **fine (crop-aware) mAP@50 ≥ 0.45** on a held-out field test. Below the bar → do NOT ship; iterate on data/model. Report per-class AP every train.
- Reuse `COARSE_GROUPS`, `GROUP_OF`, `CROP_OF`, `GROUP_DISPLAY`, `TreatmentDB` — do not fork them.
- Boxes are stored/emitted as **normalized** `[cx, cy, w, h]` (0–1) so the UI scales to any displayed size.
- Backward-compat: keep a top-level `issue`/`group`/`confidence` summary (dominant diseased box) so existing card/alert/telemetry consumers keep working unchanged.
- No new heavy runtime deps in the edge beyond `onnxruntime` (already present). Training deps live in `ml/`.
- `flutter analyze` clean + `flutter test` green + backend `pytest` green after every task.
- Branch: `per-plant-detection` off `main`.

---

### Task 1: PlantDoc detection data → YOLO format + label maps

**Files:**
- Create: `ml/detect/plantdoc_to_yolo.py`
- Create: `ml/detect/labels.py` (detection class list + group/crop maps)
- Test: `ml/detect/test_labels.py`

**Interfaces:**
- Produces: `DET_CLASSES: list[str]` (the detector's own classes, aligned to the PV label space where possible); `det_group(cls) -> str`, `det_crop(cls) -> str|None`; a YOLO dataset dir `datasets/plantdoc_yolo/{images,labels}/{train,val,test}` + `data.yaml`.

- [ ] **Step 1: Write the failing test** — `det_group`/`det_crop` map each detection class to a coarse group and crop consistent with `services.COARSE_GROUPS`/`CROP_OF`.

```python
def test_det_maps_align_with_groups():
    from ml.detect.labels import DET_CLASSES, det_group, det_crop
    for c in DET_CLASSES:
        assert det_group(c) in {"healthy","blight","leaf_spot","viral","pest"}
        assert det_crop(c) in {"tomato","potato","pepper",None}
```

- [ ] **Step 2: Run it, verify it fails** (`labels.py` absent).
- [ ] **Step 3: Implement `labels.py`** — restrict PlantDoc's 30 detection classes to the tomato/potato/pepper subset used by the classifier, map each to (group, crop). Drop other crops.
- [ ] **Step 4: Implement `plantdoc_to_yolo.py`** — clone PlantDoc (it ships VOC/XML boxes); convert to YOLO txt (`class cx cy w h` normalized); allowlist the subset; write `data.yaml`. Handle the Windows-illegal filenames (sanitize on copy). Print per-class box counts.
- [ ] **Step 5: Run the test to verify pass; run the converter on a small sample.**
- [ ] **Step 6: Commit.**

### Task 2: Train YOLO + evaluate — THE ACCURACY GATE (Colab)

**Files:**
- Create: `ml/detect/train_detector.py` (thin ultralytics wrapper)
- Create: `ml/detect/eval_detector.py` (mAP@50 overall + per-class + group-collapsed)
- Modify: `ml/colab_train.ipynb` (add a detection section)
- Modify: `ml/requirements.txt` (add `ultralytics`)

**Interfaces:**
- Consumes: `datasets/plantdoc_yolo/data.yaml`.
- Produces: `ml/runs/detect/best.pt`; an eval report `{map50, map50_95, per_class_ap, group_map50, fine_cropaware_map50}`.

- [ ] **Step 1: Write `train_detector.py`** — `YOLO("yolov8n.pt").train(data=..., imgsz=640, epochs=100, ...)`; save best.
- [ ] **Step 2: Write `eval_detector.py`** — run val; compute standard mAP@50, then a **group-collapsed** mAP (map each pred+gt class to its group) and a **crop-aware fine** mAP (constrain to gt crop). Print all three + per-class AP.
- [ ] **Step 3: Add the Colab cells** — download data, train, eval. Print the gate verdict.
- [ ] **Step 4: GATE CHECK** — run on Colab GPU. Record group mAP@50 and fine-crop-aware mAP@50.
  - If group ≥ 0.55 AND fine ≥ 0.45 → proceed to Task 3.
  - Else → STOP. Options in order: bigger backbone (yolov8s/m), more augmentation, more epochs, add in-domain captures, or restrict to fewer crops. Do not proceed to deployment tasks until the gate passes. Record the number in the plan.
- [ ] **Step 5: Commit** the scripts + the recorded eval numbers (not the weights — gitignore `*.pt`).

### Task 3: Export ONNX + backend `Detector` (letterbox + decode + NMS)

**Files:**
- Create: `ml/detect/export_detector.py`
- Create: `edge-server/app/detector.py`
- Test: `edge-server/app/tests/test_detector.py`

**Interfaces:**
- Produces: `Detector.detect(image_bytes, crop=None) -> list[Box]` where
  `Box = {"box": [cx,cy,w,h], "group": str, "fine": str, "confidence": float, "crop": str|None}`,
  normalized coords, NMS-filtered, group + crop-aware fine per box (reuse `services.GROUP_OF`/`CROP_OF`).

- [ ] **Step 1: Write the failing test** — a `Detector` pointed at the exported ONNX returns a list of boxes with normalized coords in [0,1], each carrying a valid group.

```python
def test_detector_returns_normalized_grouped_boxes():
    from detector import Detector
    from config import Settings
    det = Detector(Settings())
    if det.session is None:
        import pytest; pytest.skip("detector model not present")
    boxes = det.detect(_fake_jpeg())
    for b in boxes:
        assert len(b["box"]) == 4 and all(0.0 <= v <= 1.0 for v in b["box"])
        assert b["group"] in COARSE_GROUPS
```

- [ ] **Step 2: Run it, verify it fails** (no `detector.py`).
- [ ] **Step 3: `export_detector.py`** — `YOLO("best.pt").export(format="onnx", imgsz=640, opset=13)`; copy to `edge-server/app/models/detector.onnx` + `detector_labels.json`.
- [ ] **Step 4: Implement `Detector`** — letterbox preprocess to 640; run ONNX; decode YOLO output; class-wise NMS (pure numpy — no torch in the edge); map class→group and crop-aware fine (constrain to `crop` when given, like `predict_grouped`); return normalized boxes. Safe fallback (`session is None` → `[]`) exactly like `InferenceEngine`.
- [ ] **Step 5: Run test to verify pass.**
- [ ] **Step 6: Commit.**

### Task 4: Detection-list storage + schema + SSE

**Files:**
- Modify: `edge-server/app/schemas.py`
- Modify: `edge-server/app/routes.py` (`_record_detection`)
- Test: `edge-server/app/tests/test_api.py`

**Interfaces:**
- Consumes: `Detector.detect` output.
- Produces: cached diagnostics record `{detections:[Box...], issue, group, confidence, fine, fine_confidence, timestamp}` where the top-level fields summarize the **dominant diseased box** (backward-compat); SSE `detection` payload carries `detections`.

- [ ] **Step 1: Write the failing test** — `_record_detection` with a box list caches `detections` and a dominant-group summary; SSE `detection` event includes `detections`.
- [ ] **Step 2: Run it, verify it fails.**
- [ ] **Step 3: Add `DetectionBox` + `detections: list[DetectionBox]` to schemas; extend `_record_detection(cache, node_id, detections)`** — compute the dominant diseased box (highest-confidence non-healthy) for the `issue`/`group`/`confidence`/`fine` summary; store the full list; emit both.
- [ ] **Step 4: Run test to verify pass.**
- [ ] **Step 5: Commit.**

### Task 5: Routes wiring — boxes through analyze / upload / diagnostics / alerts

**Files:**
- Modify: `edge-server/app/routes.py`
- Modify: `edge-server/app/main.py` (construct `Detector` in lifespan; `get_detector` provider)
- Test: `edge-server/app/tests/test_api.py`

**Interfaces:**
- Consumes: `Detector`, `_crop_for_node`.
- Produces: `/analyze` + `/diagnostics` return `detections` + aggregated per-group treatments + confident per-box specific treatments; alerts raised per diseased box over threshold.

- [ ] **Step 1: Write the failing tests** — `/analyze` with a stub detector returns `detections`; treatments cover every distinct diseased group present; a diseased box > threshold logs one suggestion.
- [ ] **Step 2: Run them, verify they fail.**
- [ ] **Step 3: Add `get_detector`; swap the auto-analyze + `/analyze` from `predict_grouped` to `Detector.detect(data, crop)`; aggregate treatments over the unique diseased groups; keep the single-frame classifier as a fallback when the detector model is absent.** Alerts: one per diseased box above `disease_confidence_threshold`.
- [ ] **Step 4: Run tests to verify pass; run full `pytest`.**
- [ ] **Step 5: Commit.**

### Task 6: UI — box overlay on card + vision panel

**Files:**
- Modify: `dashboard/lib/models/telemetry.dart` (parse `detections`)
- Modify: `dashboard/lib/widgets/painters.dart` (`BoxOverlayPainter`)
- Modify: `dashboard/lib/widgets/telemetry_card.dart` (`_CameraBody` overlay)
- Modify: `dashboard/lib/screens/node_detail_screen.dart` (`_VisionPanel` overlay + per-box treatment)
- Test: `dashboard/test/detection_box_test.dart`

**Interfaces:**
- Consumes: `detections` list on the snapshot/diagnostics.
- Produces: labeled boxes drawn over the frame (scaled from normalized coords to the displayed rect), group-colored, tap-a-box → its treatment.

- [ ] **Step 1: Write the failing test** — `TelemetrySnapshot.fromJson` parses a `detections` list into typed boxes; `BoxOverlayPainter` scales a normalized box to a given size (unit-test the coord math).
- [ ] **Step 2: Run it, verify it fails.**
- [ ] **Step 3: Add a `DetectionBox` model + parsing; `BoxOverlayPainter`** (draws each normalized box scaled to `size`, group color, a small label chip, reusing the corner-bracket aesthetic).
- [ ] **Step 4: Overlay boxes** in `_CameraBody` (compact, boxes only) and `_VisionPanel` (boxes + tap → per-box group/specific treatment). Fall back to the single-detection UI when `detections` is empty.
- [ ] **Step 5: `flutter analyze` + `flutter test`.**
- [ ] **Step 6: Commit.**

### Task 7: End-to-end verification + deployment gate

**Files:**
- Modify: `ml/OVERNIGHT_REPORT.md` / a new `ml/detect/REPORT.md` (record numbers)
- Modify: `docs/mqtt-schema.md` / API docs (document the `detections` payload)

- [ ] **Step 1:** Rebuild the dev API with `detector.onnx`; upload a real multi-plant leaf frame via `classify.py`; confirm multiple boxes come back with per-box groups + treatments.
- [ ] **Step 2:** Confirm the dashboard + app draw the boxes (verify via the running dev server; note the CanvasKit screenshot limitation — verify via network payload + widget tests if pixels aren't capturable).
- [ ] **Step 3: Re-affirm the gate** — record the deployed detector's group/fine mAP in the report. If it regressed below the bar, revert to the classifier path (kept as fallback) and do not advertise per-plant detection.
- [ ] **Step 4:** Merge `per-plant-detection` → `main`, tag `per-plant-detection-complete`, push.

---

## Sequencing & risk notes
- **Order: 1 → 2 → (GATE) → 3 → 4 → 5 → 6 → 7.** Task 2's accuracy gate is a hard stop — the whole point of the user's requirement is to not ship a weak per-plant diagnosis. If the gate fails, the fallback is the existing group+crop classifier (already live), which stays the shipped behavior.
- **Biggest risk is detector accuracy on PlantDoc** (small, noisy boxes). Mitigations, cheapest first: group-level reporting (reliable even when fine is shaky), crop-aware fine, bigger YOLO variant, and — the real ceiling-breaker — **in-domain ESP32-CAM captures with boxes** (a labeling loop worth starting in parallel).
- The classifier path (`predict_grouped`) is retained as a fallback and for single-plant frames; the detector supersedes it only when its model is present and passed the gate.
- Inference cost: YOLOv8n ONNX at 640 on the Pi-5 CPU is heavier than the classifier — measure latency in Task 5; if too slow, drop to imgsz 480 or yolov8n-only, or run detection less often than every frame.
