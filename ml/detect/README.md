# Per-plant detector (sub-project B)

A YOLO detector that boxes and diagnoses each plant in a frame — so one camera
over several plants gives a per-plant diagnosis, not one whole-frame label. Each
box collapses to the reliable coarse group (and, with the node's crop, a specific
disease), reusing the same group/crop/treatment stack as the classifier.

## Pipeline (GPU / Colab recommended)

```bash
pip install -r ml/requirements.txt      # adds ultralytics

# 1. Get PlantDoc DETECTION data into datasets/plantdoc_detect/
#    EASIEST: Roboflow Universe → search "PlantDoc" → Download → "YOLOv8" (or
#    "COCO"), unzip into datasets/plantdoc_detect/. Pascal-VOC (*.xml) also works.
#    The converter auto-detects VOC / Roboflow-YOLO / COCO — no need to pick.

# 2. Convert → YOLO in OUR class order (remaps any format, drops other crops)
python ml/detect/plantdoc_to_yolo.py \
    --src datasets/plantdoc_detect --out datasets/plantdoc_yolo
#    Prints boxes-per-class; if it maps 0 boxes, the class names don't match —
#    check ml/detect/labels.py PLANTDOC_TO_DET against your data's names.

# 3. Train (bigger --model is the first lever if the gate fails)
python ml/detect/train_detector.py \
    --data datasets/plantdoc_yolo/data.yaml --model yolov8n.pt --epochs 120

# 4. THE ACCURACY GATE — do not deploy unless this passes
python ml/detect/eval_detector.py \
    --weights ml/runs/detect/train/weights/best.pt \
    --data datasets/plantdoc_yolo/data.yaml --split test
#   PASS requires group mAP@50 >= 0.55 AND fine mAP@50 >= 0.35.
#   FAIL → yolov8s/m, more epochs/augmentation, or (the real fix) in-domain
#   ESP32-CAM captures labelled with boxes. Keep the classifier fallback shipped.

# 5. Export for the edge (only after the gate passes)
python ml/detect/export_detector.py \
    --weights ml/runs/detect/train/weights/best.pt --out edge-server/app/models
#   → detector.onnx + detector_labels.json. The edge auto-uses it when present.
```

## Why a detector (and why the gate)
Whole-frame classification can't localise multiple plants and tops ~44% fine on
field images. A detector localises each region and is evaluated per-box; the
group-level mAP is the reliable signal the deployment gates on. The gate exists
so we never ship a weak per-plant diagnosis — below it, the existing group+crop
classifier stays the live behaviour.

## Files
| File | Role |
|---|---|
| `labels.py` | 15 detector classes + group/crop maps + PlantDoc name mapping |
| `plantdoc_to_yolo.py` | VOC-XML → YOLO dataset (Windows-safe, class allowlist) |
| `train_detector.py` | ultralytics YOLO training wrapper |
| `eval_detector.py` | fine + group mAP@50, prints the GATE verdict |
| `export_detector.py` | best.pt → ONNX for the edge (added in B-Task3) |
