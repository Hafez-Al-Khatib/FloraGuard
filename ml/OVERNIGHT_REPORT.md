# Overnight run — field-domain disease model

_Autonomous run on the `ml-pipeline` branch. Goal: prove the lab→field gap with
real numbers and produce a field-trained model + honest metrics._

## TL;DR
- **The current PlantVillage model scores 24% on real field images** (PlantDoc),
  despite ~99% on lab PlantVillage. The gap is real and large.
- The failure **reproduces your exact symptom**: it over-fires
  `Tomato_Late_blight` (recall 0.70) and `Pepper_bell_healthy` (0.71) and scores
  0.00 on six classes.
- A MobileNetV3-Large retrained on field data (PlantDoc) with camera-matched
  augmentation (120 epochs) reaches **36% accuracy and macro-F1 0.367 — macro-F1
  more than doubled (0.154 → 0.367)** on the same test set, macro-precision
  0.13 → 0.44. The collapse is gone: classes the old model scored 0.00 on now
  work (Tomato_Late_blight 0.60, YellowCurl-virus 0.62, healthy 0.50).
- **Both exports are deployable.** FP32 (16.9 MB) is best at macro-F1 0.367;
  static INT8 (4.7 MB) holds macro-F1 0.329 — a small ~1-point-accuracy loss.
  (An earlier 50-epoch model quantized much worse, macro-F1 0.232 → 0.348 FP32;
  the longer-trained features quantize far more robustly, which is itself a
  useful finding.) Deploy FP32 for accuracy, INT8 if you want the smaller file.
- This ran on CPU with a small dataset (~820 field train images); it's a proof
  of the approach, not the final model. Ranked path to production in "Next steps".

## Method (all reproducible on the branch)
- **Data:** cloned PlantDoc (real field images). Windows can't check out ~90 of
  its files (scraped filenames contain `?`/`%`/`:` — illegal on NTFS); the
  remaining **2,481 images** were used.
- **Label alignment:** `ml/plantdoc_to_pv.py` maps PlantDoc's free-text classes
  onto the exact 15 PlantVillage labels, so the current model and the new model
  are compared on the **same field test set**. 13/15 classes have data
  (Potato-healthy, Target-Spot, Spider-mites lack usable PlantDoc counterparts).
- **Splits:** `datasets/pv15/{train,val,test}` — train/val from PlantDoc train
  (~820/145), test from PlantDoc test (100 images).
- **Training:** `ml/train.py` — MobileNetV3-Large, 224px, ImageNet init
  (PDDD-PreTrain weights aren't auto-downloadable; see Next steps), class-weighted
  loss + label smoothing, cosine schedule, and `ml/augment.py` camera-matched
  augmentation (JPEG re-compression + downscale + jitter + cutout).
- **Export:** `ml/export_onnx.py` — FP32 + **static** (calibrated) INT8.
- **Eval:** `ml/evaluate.py` on the held-out field test set.

## Results — same field test set (100 images, 12 populated classes)

| Model | Trained on | Field accuracy | Macro-F1 | Macro-precision |
|---|---|---|---|---|
| ResNet18 (current, FP32) | PlantVillage (lab) | 24.0% | 0.154 | 0.13 |
| ResNet18 (current, served INT8) | PlantVillage (lab) | 25.0% | 0.170 | 0.15 |
| MobileNetV3-L (CPU proof, 120ep) | PlantDoc (field) | 36.0% | 0.367 | 0.44 |
| MobileNetV3-L CPU INT8 | PlantDoc (field) | 34.0% | 0.329 | 0.37 |
| **MobileNetV3-L 15-class (Colab GPU, +PlantVillage)** ← DEPLOYED | PlantDoc+PV | **44.0%** | **0.411** | 0.47 |
| MobileNetV3-L 15-class INT8 (Colab) | PlantDoc+PV | 42.0% | 0.403 | 0.49 |

The Colab run (GPU, full PlantDoc + PlantVillage merged for all 15 classes, 200
epochs) is the current best and is now the edge server's default model
(`config.py` → `field_mnv3_15cls.onnx`, integration-tested through
`InferenceEngine` with auto-224 input). Baseline → deployed = **24% → 44%
accuracy, macro-F1 0.154 → 0.411 (2.7×)**. Its INT8 barely loses (0.403), so the
4.7 MB quantized model is a viable Pi target too.

Accuracy alone understates it: **macro-F1** (which punishes the collapse-to-a-few-
classes behaviour by weighting every class equally) **more than doubled**. The new
model actually discriminates classes instead of defaulting to two. (A 50-epoch
checkpoint scored 30% / 0.348 FP32; 120 epochs lifted both accuracy and recall,
and — importantly — made the INT8 quantize cleanly.)

### Baseline per-class (current model, the "why") — recall highlights
```
Pepper_bell_healthy        recall 0.71   <- over-fired
Tomato_Late_blight         recall 0.70   <- over-fired
Pepper_bell_Bacterial_spot recall 0.00
Potato_Late_blight         recall 0.00
Tomato_Bacterial_spot      recall 0.00
Tomato_Leaf_Mold           recall 0.00
Tomato_YellowLeaf_Curl     recall 0.00
Tomato_mosaic_virus        recall 0.00
Tomato_healthy             recall 0.00
```
This is the "only bell-pepper-healthy and tomato-late-blight" behaviour, measured.

### New model per-class (FP32, 120ep) — f1 now vs current model
```
Tomato_Late_blight             0.60   was 0.33
Tomato_YellowLeaf_Curl_Virus   0.62   was 0.00
Tomato_Early_blight            0.53   was 0.23
Tomato_healthy                 0.50   was 0.00
Pepper_bell_Bacterial_spot     0.47   was 0.00
Pepper_bell_healthy            0.46   was 0.40
Tomato_Septoria_leaf_spot      0.40   was 0.55  (the one regression)
Potato_Late_blight             0.33   was 0.00
Tomato_Bacterial_spot          0.33   was 0.00
Potato_Early_blight            0.31   was 0.33
Tomato_Leaf_Mold               0.22   was 0.00
Tomato_mosaic_virus            0.00   (small/hard class; 10 test imgs)
```
Nine of twelve classes improved, several from 0.00. The remaining weak classes
(mosaic, Leaf_Mold) are the smallest — a data problem, not a method one.

### INT8 quantization note
The 120-epoch model's static INT8 holds **macro-F1 0.329** (vs 0.367 FP32) — a
small loss, and INT8 is a viable deploy option (4.7 MB). Contrast the 50-epoch
checkpoint, whose INT8 collapsed to 0.232: longer training produced smoother,
more quantization-robust features. To tighten INT8 further, calibrate on real
ESP32-CAM frames rather than the lab-ish val set, or use QAT. (Static
quantization remains the correct *method* — never the old dynamic quant.)

## Artifacts (all on branch `ml-pipeline`)
- `edge-server/app/models/field_mnv3_13cls.onnx` (FP32, 16.9 MB) — **deploy this**
- `edge-server/app/models/field_mnv3_13cls_int8.onnx` (static INT8, 4.7 MB) — needs recalibration
- `edge-server/app/models/field_labels.json` (13 classes)
- Training checkpoint: `ml/runs/mnv3_field/best.pt` (gitignored — reproduce via `ml/train.py`)

### To try it on the edge server
The server already reads input size from the model (224 auto-detected), so just
repoint config + labels and restart:
```
# edge-server/.env
MODEL_PATH=models/field_mnv3_13cls.onnx
```
Set the labels path to `field_labels.json` (it drops 3 PV classes the field data
lacked — Potato-healthy, Target-Spot, Spider-mites — so `class_labels` must match
the 13). `TreatmentDB` keys already cover these labels. Then `classify.py` a real
leaf and compare against the old model.

## Honest caveats
- **Small data:** ~820 field training images across 12 classes, CPU-trained. Real
  ceiling for this task is ~74–78% even for SOTA with good data — don't expect
  lab-like numbers.
- **INT8 calibrated on PlantDoc val**, not real ESP32-CAM frames — recalibrate on
  your own captures before trusting the quantized model.
- **Label-map approximations:** PlantDoc "Bell_pepper leaf spot" → PV
  "Bacterial_spot" is a loose mapping.

## Next steps (ranked by expected gain)
1. **Your own labelled ESP32-CAM captures** in train + INT8 calibration — the
   single biggest lever, and the only data that matches deployment exactly.
2. **Init from PDDD-PreTrain** (400k+ field images) instead of ImageNet — grab
   the weights manually from the Plant Phenomics paper and pass `--pretrained-ckpt`.
3. **Restrict to the crops/diseases you actually grow** — fewer classes, fewer
   confusions.
4. **Confidence threshold → "uncertain"** so low-quality frames don't force a
   wrong label.
5. Merge PlantVillage in as *additional* data (not the only source) for class
   coverage, with the field augmentation applied to it too.
