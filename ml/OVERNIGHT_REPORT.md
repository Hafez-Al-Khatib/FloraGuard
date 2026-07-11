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
  augmentation reaches **30% accuracy and macro-F1 0.348 — macro-F1 more than
  doubled (0.154 → 0.348)** on the same test set, and macro-precision went
  0.13 → 0.55. The collapse is gone: classes the old model scored 0.00 on now
  work (YellowCurl-virus 0.73, healthy 0.55, mosaic 0.46).
- **Deploy the FP32 export, not INT8.** Static INT8 lost too much here
  (macro-F1 0.348 → 0.232) — MobileNetV3's h-swish/SE blocks are
  quantization-sensitive and calibration used only 145 non-camera images. FP32
  is 16.9 MB and fast on a Pi 5; fix INT8 later with real-frame calibration/QAT.
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
| **MobileNetV3-L (new, FP32)** ← deploy | PlantDoc (field) | **30.0%** | **0.348** | **0.55** |
| MobileNetV3-L (new, static INT8) | PlantDoc (field) | 20.0% | 0.232 | 0.33 |

Accuracy alone understates it: **macro-F1** (which punishes the collapse-to-a-few-
classes behaviour by weighting every class equally) **more than doubled**, and
macro-precision went from 0.13 → 0.55. The new model actually discriminates
classes instead of defaulting to two.

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

### New model per-class (FP32) — classes that went from 0.00 → real
```
Tomato_YellowLeaf_Curl_Virus  f1 0.73  (precision 0.80, recall 0.67)   was 0.00
Tomato_healthy                f1 0.55  (precision 1.00, recall 0.38)   was 0.00
Potato_Early_blight           f1 0.53  (precision 0.57, recall 0.50)   was 0.33
Tomato_Late_blight            f1 0.53  (precision 0.56, recall 0.50)   was 0.33
Tomato_mosaic_virus           f1 0.46  (precision 1.00, recall 0.30)   was 0.00
Pepper_bell_healthy           f1 0.44  (precision 1.00, recall 0.29)   was 0.40
Tomato_Septoria_leaf_spot     f1 0.43  (precision 1.00, recall 0.27)   was 0.55
```
Trade-off: the new model is far more *precise* (few false positives) but
*conservative* (lower recall) on the tiny 100-image test — more data and epochs
would lift recall. `Tomato_Leaf_Mold` is still 0.00 (only 6 test / 79 train).

### INT8 quantization note
Static INT8 dropped macro-F1 to 0.232. MobileNetV3's hard-swish + squeeze-excite
blocks quantize poorly, and calibration used 145 lab-ish val images, not real
ESP32-CAM frames. **Deploy FP32** for now; to recover INT8 later: calibrate on
real cam captures, or use quantization-aware training (QAT). The *method*
(static > dynamic) is still correct — this backbone + tiny calib set is the issue.

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
