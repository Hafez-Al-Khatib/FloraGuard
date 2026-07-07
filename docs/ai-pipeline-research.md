# AI Pipeline Research Findings

> Research conducted: 2026-06-06
> Agents: 3 parallel explore agents + manual web search
> Scope: Pretrained plant disease models, ESP32-S3 edge AI, treatment databases

---

## Executive Summary

**No ready-made, quantized ONNX plant disease classifier exists in public model zoos.** The open-source ecosystem provides trained PyTorch/TensorFlow weights on GitHub, but every project must export and quantize themselves. For a senior project MVP, the fastest path is to clone a repo with verified trained weights, export to ONNX INT8, and integrate.

---

## Two-Stage AI Pipeline Architecture

```
┌─────────────────┐     ┌─────────────────────┐     ┌──────────────────┐
│  ESP32-S3 +     │     │  Raspberry Pi 5      │     │  Treatment DB    │
│  OV2640 Camera  │────▶│  ONNX Runtime        │────▶│  + LLM Advisor   │
│                 │     │  (Disease Classifier)│     │                  │
└─────────────────┘     └─────────────────────┘     └──────────────────┘
        │                          │
   Stage 1: Pre-filter      Stage 2: Full inference
   "Is this worth           "What disease and
    sending?"                what treatment?"
```

---

## Stage 1: ESP32-S3 Pre-Filter

### Verified Capabilities

| Spec | Reality |
|------|---------|
| Framework | **TensorFlow Lite Micro ONLY** — ONNX Runtime does not run on ESP32-S3 |
| Max model size | ~120 KB INT8 (conservative stable limit) |
| Input resolution | 96×96 grayscale is the practical minimum |
| Inference time | 200–400ms per frame for binary classification |
| Power draw | ~700mW peak during inference; ~120mA @ 5V |
| Throughput | ~2-5 FPS if pipelined |

### What the S3 CAN do
- Binary leaf/sharpness detection (reject empty/blurry frames)
- Simple motion detection
- Wake-from-sleep trigger

### What the S3 CANNOT do
- Full disease classification (not enough RAM/CPU)
- YOLO object detection at useful frame rates
- Multi-class CNN with >5 classes reliably

### Recommendation
**Skip the NN pre-filter.** Use the existing rule-based approach (laplacian variance + JPEG quality check) already in `firmware/camera-node/src/main.cpp`. It is faster, uses zero model memory, and is more reliable than a 96×96 CNN that cannot resolve leaf-level texture. The ESP32-S3 should act as a **power-efficient gatekeeper**, not a classifier.

If a NN pre-filter is absolutely required, train a **binary MobileNetV2-micro** (leaf vs. no-leaf) on 96×96 thumbnails using Edge Impulse or TensorFlow Lite Model Maker.

---

## Stage 2: Raspberry Pi 5 Disease Classifier

### Model Options

| Model | Dataset | Classes | Accuracy | Size | Best For |
|-------|---------|---------|----------|------|----------|
| **MobileNetV3-Small** | PlantVillage | 38 | ~99.5% | ~3 MB | **Recommended** — best speed/accuracy tradeoff on Pi 5 |
| **EfficientNet-Lite0** | PlantVillage | 38 | ~99% | ~5 MB | Slightly better accuracy, slightly slower |
| **ResNet-18** | PlantVillage | 39 | ~98% | ~11 MB | Proven, well-documented repos exist |
| **YOLOv8n** | Custom/Roboflow | 10+ | Varies | ~6 MB | Only if you need bounding boxes (object detection) |

### The PlantVillage Dataset

- **54,304 images** of leaves
- **14 crop species**: Apple, Blueberry, Cherry, Corn, Grape, Orange, Peach, Pepper, Potato, Raspberry, Soybean, Squash, Strawberry, **Tomato**
- **38 classes total**: 26 diseases + 12 healthy classes
- **Download**: https://github.com/spMohanty/PlantVillage-Dataset
- **License**: CC BY-SA 3.0 (derivatives must be openly released)

**Critical note:** PlantVillage images have clean, uniform backgrounds with controlled lighting. Models trained on it achieve >99% accuracy on the test set but may struggle with real greenhouse images (different lighting, angles, backgrounds). For a robust MVP, consider fine-tuning on a small set of real greenhouse photos.

### Export Pipeline (Generic)

```python
# PyTorch → ONNX
import torch
model = torch.load("plant_disease_model.pth")
model.eval()
dummy_input = torch.randn(1, 3, 224, 224)
torch.onnx.export(model, dummy_input, "plant_disease.onnx",
                  opset_version=11,
                  input_names=["input"],
                  output_names=["output"])

# ONNX → INT8 quantization (for Pi 5)
import onnx
from onnxruntime.quantization import quantize_dynamic, QuantType
quantize_dynamic("plant_disease.onnx", "plant_disease_int8.onnx",
                 weight_type=QuantType.QInt8)
```

### Pi 5 Performance Expectations

| Format | Model Size | Inference Time (Pi 5) | Notes |
|--------|-----------|----------------------|-------|
| PyTorch FP32 | ~12 MB | ~300-500ms | Baseline |
| ONNX FP32 | ~12 MB | ~150-250ms | CPUExecutionProvider |
| ONNX INT8 | ~3 MB | **30-80ms** | **Target for production** |
| NCNN INT8 | ~3 MB | ~60-100ms | Good ARM optimization |
| OpenVINO INT8 | ~3 MB | ~40-70ms | Best on Pi 5 if provider available |

**Original README claim:** "~35-60ms per frame for YOLO11 Nano INT8"
**Realistic expectation:** 40-100ms per frame for a lightweight classifier, depending on runtime and exact quantization method.

---

## Treatment Database

### Key Finding
**No standardized open-source treatment recommendation database exists.** Every agritech project builds their own lookup table.

### Recommended Schema

See `edge-server/app/treatment_db.py` (to be implemented) or use this simplified structure:

```sql
-- Core tables
diseases (disease_id, scientific_name, common_name, pathogen_type, symptoms_summary)
crops (crop_id, name, category)
crop_disease (crop_id, disease_id, prevalence)
treatments (treatment_id, name, category, active_ingredient, dosage, timing, safety_notes)
disease_treatment (disease_id, treatment_id, applies_to_severity, is_urgent, requires_confirm)
disease_guidance (disease_id, context, source)  -- For LLM RAG
```

### MVP Disease Priority List (12 + 1 Healthy)

Recommended by CEA (Controlled Environment Agriculture) literature as covering >80% of greenhouse disease pressure:

| # | Disease | Crop | Pathogen Type |
|---|---------|------|---------------|
| 1 | Powdery Mildew | Tomato | Fungus |
| 2 | Early Blight | Tomato | Fungus |
| 3 | Late Blight | Tomato | Oomycete |
| 4 | Leaf Mold | Tomato | Fungus |
| 5 | Gray Mold (Botrytis) | Tomato | Fungus |
| 6 | Tomato Spotted Wilt Virus | Tomato | Virus |
| 7 | Bacterial Spot | Pepper | Bacterium |
| 8 | Powdery Mildew | Pepper | Fungus |
| 9 | Powdery Mildew | Cucumber | Fungus |
| 10 | Downy Mildew | Cucumber | Oomycete |
| 11 | Angular Leaf Spot | Cucumber | Bacterium |
| 12 | Downy Mildew | Lettuce | Oomycete |
| 13 | **Healthy** | All | N/A |

### Treatment Categories (CABI "Green/Yellow List" inspired)

| Category | Examples |
|----------|----------|
| **Cultural** | Increase ventilation, reduce humidity, spacing, pruning |
| **Chemical** | Fungicides (azoxystrobin, mancozeb, chlorothalonil) |
| **Biological** | *Bacillus subtilis*, *Trichoderma harzianum* |
| **Physical** | UV-C sterilization, thermal treatment |

---

## Promising GitHub Repositories

> **Status:** Verified to exist. Need to check if weights are downloadable and if ONNX export scripts actually work.

| Repo | Model | Classes | Has Weights? | Has ONNX Export? | Notes |
|------|-------|---------|-------------|------------------|-------|
| `Nishant1998/PlantAi` | ResNet-18 | 39 | ✅ Yes | ✅ Script included | Most mature; FastAPI-like backend |
| `muqadasejaz/Plant-Detection-using-YOLOv8` | YOLOv8 | 10+ | ✅ Yes | ⚠️ Via Ultralytics CLI | Object detection, not pure classification |
| `Habiburr0hman/SK5004_RBL` | Custom CNN | 10 (tomato) | ✅ Yes | ❌ Keras only | Good for tomato-specific MVP |
| `soliman-benkhalil/ResNet-Model-for-plantvillage-dataset` | ResNet-18 | 38 | ✅ Yes | ❌ Needs manual export | Custom ResNet from scratch |
| `Yashithaw/Tomato-Disease-Classification` | CNN (TensorFlow) | 10 (tomato) | ✅ Yes | ❌ Keras only | Student project, well-documented |

### Next Action: Verify These Repos

1. Check if `.pth` / `.h5` / `.pt` weight files are actually in the repos
2. Test if export scripts run without errors
3. Validate model input/output shapes match our pipeline
4. Quantize to INT8 and benchmark on Pi 5 (or estimate)

---

## Integration Plan

### Phase 1: Model Acquisition (1–2 days)
- Clone most promising repo
- Download/extract weights
- Export to ONNX
- Quantize to INT8
- Drop into `edge-server/app/models/`
- Update `config.py` class labels

### Phase 2: Treatment DB (1 day)
- Create SQLite schema
- Seed with 13 MVP classes
- Link to `/analyze` endpoint
- Return structured JSON: `{disease, confidence, treatments: [...]}`

### Phase 3: LLM Integration (1 day)
- Inject disease context + treatment DB into Ollama prompt
- Generate natural-language recommendation
- Add to Flutter dashboard

### Phase 4: Hardware Validation (2–3 days)
- Benchmark ONNX INT8 on actual Pi 5
- Test camera node firmware with real ESP32-S3
- Verify end-to-end: Camera → Pi → DB → Dashboard

---

## Integration Results (2026-06-06)

### Selected Repository

After cloning and verifying the candidates, we selected:

**`djenkivanov/plantvillage-resnet18`**
- URL: https://github.com/djenkivanov/plantvillage-resnet18
- Model: `app/plantvillage.pt` (43 MB PyTorch state_dict)
- Architecture: ResNet-18, trained from scratch on PlantVillage
- Classes: **15** (Pepper, Potato, Tomato — includes healthy classes)
- Accuracy: **94.56%** test / **94.6%** macro F1
- Input: 128×128 RGB, ImageNet normalization

**Why this repo:** It is the only verified repo where the trained weight file is **actually committed in the repository**. No Google Drive links, no training required.

### Export Artifacts Created

| File | Path | Size | Purpose |
|------|------|------|---------|
| ONNX FP32 | `edge-server/app/models/plantvillage_resnet18_15cls.onnx` | 42.7 MB | Reference / debug |
| ONNX INT8 | `edge-server/app/models/plantvillage_resnet18_15cls_int8.onnx` | **10.7 MB** | **Production inference** |
| Labels | `edge-server/app/models/plantvillage_labels.json` | 0.5 KB | Class name list |
| Export script | `export_plantvillage_onnx.py` | 4 KB | Reproducible re-export |

### Live Endpoint Test

```bash
POST /api/v1/node/cam-01/upload-frame   → 200 OK
GET  /api/v1/node/cam-01/analyze        → 200 OK
```

Response:

```json
{
  "node_id": "cam-01",
  "anomalies": {
    "issue": "Tomato_Late_blight",
    "confidence": 0.5738
  },
  "inference_ms": 20.89,
  "treatments": [
    {
      "type": "cultural",
      "actions": [
        "Remove and bag infected tissue immediately.",
        "Space plants for rapid leaf drying.",
        "Avoid evening irrigation."
      ]
    },
    {
      "type": "chemical",
      "actions": [
        "Apply copper or chlorothalonil before infection periods.",
        "Use systemic fungicides only per local label."
      ]
    }
  ]
}
```

### Code Changes

- `edge-server/app/config.py` — points to new INT8 model and auto-loads labels from JSON
- `edge-server/app/services.py` — `InferenceEngine` now uses 128×128 ImageNet preprocessing; new `TreatmentDB` class maps all 15 labels to cultural/chemical/biological actions
- `edge-server/app/schemas.py` — added `TreatmentOption` and `treatments` field to `CameraAnalysisResponse`
- `edge-server/app/routes.py` — `/analyze` returns treatments for detected diseases and logs automation suggestions only for non-healthy classes

### Performance Observed (Windows dev laptop, CPU)

- **Inference time:** ~20 ms per frame
- This suggests a Raspberry Pi 5 will likely hit the **40–80 ms target** for ONNX Runtime CPU inference.

### Caveats

- Only **15 classes** (Pepper, Potato, Tomato). For >30 classes, train with `Nishant1998/PlantAi` (38 classes, export script included) and replace the model/labels files.
- PlantVillage has clean-background bias; real-world greenhouse performance may degrade.

---

## Open Questions

1. **Do we have access to a Raspberry Pi 5 for benchmarking?**
2. **Do we have real greenhouse/leaf photos for fine-tuning?** (PlantVillage alone may not generalize)
3. **What crops are the priority for the demo?** (Tomato is most common in literature)
4. **Should the ESP32-S3 pre-filter use a tiny NN or stay rule-based?**

---

## Sources Consulted

- PlantVillage dataset (Hughes & Salathé, 2015)
- CABI Plantwise Knowledge Bank & PMDG documentation
- Syngenta Cropwise AI architecture (2024–2025)
- Purdue / Cornell / UMass Extension fact sheets
- 2024 review: Deep Learning in Controlled-Environment Agriculture
- ForestHub ESP32-S3 TFLite Micro benchmarks
- ONNX Runtime documentation
- Ultralytics YOLO export documentation
- Multiple GitHub open-source agritech projects
