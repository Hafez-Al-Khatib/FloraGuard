# Field-robust disease model pipeline

The shipped model (`plantvillage_resnet18_15cls`) was trained on **PlantVillage**
— single centred leaves on uniform lab backgrounds. It scores ~1.0 on those
images (verified) but collapses in the field: real ESP32-CAM captures are
low-res, JPEG-compressed, and full of background. That gap is a **data/domain**
problem, not a code bug — the edge server's preprocessing is correct. This
pipeline retrains on field data with camera-matched augmentation and exports a
properly-quantized ONNX model that drops into the edge server.

## What this produces
- `field_mnv3_<n>cls.onnx` — MobileNetV3-Large, 224×224, FP32
- `field_mnv3_<n>cls_int8.onnx` — **static** (calibrated) INT8, the deploy target
- `field_labels.json` — class order = model output index order

## Why these choices
- **MobileNetV3-Large**: best accuracy/latency on Pi-5 CPU; quantizes cleanly.
  The ~74–78% ceiling for real-world plant disease (ViT/MoE and PlantDoc-trained
  SOTA) means a heavier backbone buys little — data + augmentation dominate.
- **Init from PDDD-PreTrain** (400k+ field images, 120 disease classes) instead
  of ImageNet — the single biggest generalization lever you can download.
  Get weights via the paper: https://spj.science.org/doi/10.34133/plantphenomics.0054
- **Static INT8, not dynamic**: the old `export_plantvillage_onnx.py` used
  `quantize_dynamic`, which does ~nothing for a Conv net. Static quant with
  real-frame calibration is correct and is what `export_onnx.py` does.

## Train on GPU (Colab) — recommended
CPU training is data/epoch-limited. `ml/colab_train.ipynb` runs this exact
pipeline on a free Colab T4: full PlantDoc (Linux checks out every file),
optional PlantVillage merge for all 15 classes + more data, 200 epochs, then
export + field eval + download. Open it in Colab, set `REPO_URL`, Runtime → GPU,
Run all. Helper: `ml/add_plantvillage.py` merges PlantVillage into the field
split under the exact label names (TreatmentDB-compatible).

## Tuning & quantization
- **`ml/sweep.py`** — Optuna search over backbone / resolution / lr / weight-decay
  / label-smoothing / dropout, optimizing validation macro-F1; prints the winning
  `train.py` command. Model quality (not quantization) is the accuracy ceiling, so
  this is the highest-value knob. Sweep on a coarse dataset to tune the deployed
  5-group metric directly.
- **`ml/export_onnx.py --quant {static,dynamic,fp16,none}`** (+ `--exclude-nodes`
  for mixed precision). On the deployed coarse metric, static INT8 costs ~1 pt for
  3.6× smaller — already Pi-ready. On a Pi 5, FP32 is also fast; INT8 mainly saves
  size/memory.

## Steps (local CPU)

```bash
# 0. Environment (separate from the edge-server venv)
python -m venv ml/.venv
ml/.venv/Scripts/pip install -r ml/requirements.txt   # (Scripts/ on Windows, bin/ on Linux)

# 1. Get datasets (into ./datasets, which is gitignored)
#    - PlantDoc (field images):  https://github.com/pratikkayal/PlantDoc-Dataset
#    - optionally PlantVillage for class coverage
#    - BEST: a few hundred of your OWN ESP32-CAM captures per class
#    - PDDD-PreTrain weights -> ./weights/

# 2. Assemble an ImageFolder train/val split, restricted to the crops you grow
python ml/prepare_data.py \
    --source datasets/plantdoc/train \
    --source datasets/my_cam_captures \
    --classes tomato_late_blight tomato_early_blight tomato_healthy \
              pepper_bell_bacterial_spot pepper_bell_healthy \
    --val-frac 0.15 --out datasets/prepared

# 3. Fine-tune (GPU strongly recommended)
python ml/train.py \
    --data datasets/prepared \
    --pretrained-ckpt weights/pddd_mobilenetv3_large.pth \
    --epochs 40 --img-size 224 --out ml/runs/mnv3_field

# 4. Export FP32 + static INT8, calibrated on real frames
python ml/export_onnx.py \
    --ckpt ml/runs/mnv3_field/best.pt \
    --calib-dir datasets/prepared/val \
    --out edge-server/app/models

# 5. Sanity-check the field accuracy of BOTH exports
python ml/evaluate.py --model edge-server/app/models/field_mnv3_<n>cls.onnx \
    --labels edge-server/app/models/field_labels.json --data datasets/prepared/val
python ml/evaluate.py --model edge-server/app/models/field_mnv3_<n>cls_int8.onnx \
    --labels edge-server/app/models/field_labels.json --data datasets/prepared/val
```

## Wire it into the edge server
Point the server at the new files (no code change needed for the resolution —
`InferenceEngine` now reads the input size from the model):

`edge-server/.env` (or config defaults):
```
MODEL_PATH=models/field_mnv3_<n>cls_int8.onnx
```
Ensure `field_labels.json` sits beside it (config auto-loads
`<model>.with_name("...labels.json")` — rename or adjust the labels path to
match). Then restart the stack and re-run `classify.py` against a real leaf.

Also update `TreatmentDB._MAPPING` in `services.py` for any new class labels so
the dashboard shows treatments for them.

## Reality check on expectations
Field accuracy will land well below the fake PlantVillage 99% — plan for
~70–85% on your own crops with good data. The biggest wins, in order:
1. Your own labelled ESP32-CAM captures in the training + calibration sets.
2. Restricting to the few crops/diseases you actually grow.
3. A confidence threshold that returns "uncertain" instead of forcing a label.
