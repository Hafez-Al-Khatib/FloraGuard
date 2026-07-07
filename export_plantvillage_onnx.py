"""Export djenkivanov/plantvillage-resnet18 PyTorch weights to ONNX FP32 and INT8.

Usage from project root:
    edge-server/app/.venv/Scripts/python export_plantvillage_onnx.py
"""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn
from torchvision.models import resnet18

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
PROJECT_ROOT = Path(__file__).resolve().parent
REPO_DIR = PROJECT_ROOT / "temp-plant-model-repo"
CKPT = REPO_DIR / "app" / "plantvillage.pt"
LABELS = REPO_DIR / "app" / "labels.json"
MODELS_DIR = PROJECT_ROOT / "edge-server" / "app" / "models"
MODELS_DIR.mkdir(parents=True, exist_ok=True)

ONNX_FP32 = MODELS_DIR / "plantvillage_resnet18_15cls.onnx"
ONNX_INT8 = MODELS_DIR / "plantvillage_resnet18_15cls_int8.onnx"
LABELS_OUT = MODELS_DIR / "plantvillage_labels.json"

# ---------------------------------------------------------------------------
# Replicate the source model architecture
# ---------------------------------------------------------------------------
class CustomNet(nn.Module):
    def __init__(self, num_classes: int = 15):
        super().__init__()
        model = resnet18(weights=None)
        model.fc = nn.Linear(model.fc.in_features, num_classes)
        self.resnet18 = model

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return self.resnet18(x)


def load_model(ckpt_path: Path, num_classes: int = 15) -> tuple[nn.Module, list[str]]:
    with open(LABELS) as f:
        class_to_idx = json.load(f)
    class_names = [k for k, _ in sorted(class_to_idx.items(), key=lambda kv: kv[1])]

    model = CustomNet(num_classes)
    state = torch.load(ckpt_path, map_location="cpu", weights_only=True)
    state = state.get("model_state", state)
    if any(k.startswith("module.") for k in state):
        state = {k.replace("module.", ""): v for k, v in state.items()}
    model.load_state_dict(state, strict=True)
    model.eval()
    return model, class_names


def export_onnx(model: nn.Module, path: Path) -> None:
    dummy = torch.randn(1, 3, 128, 128, requires_grad=False)
    torch.onnx.export(
        model,
        dummy,
        path,
        export_params=True,
        opset_version=13,
        do_constant_folding=True,
        input_names=["input"],
        output_names=["output"],
        dynamic_axes={
            "input": {0: "batch_size"},
            "output": {0: "batch_size"},
        },
        dynamo=False,
    )
    print(f"Exported FP32 ONNX -> {path} ({path.stat().st_size / 1024 / 1024:.2f} MB)")


def quantize_to_int8(fp32_path: Path, int8_path: Path) -> None:
    try:
        from onnxruntime.quantization import quantize_dynamic, QuantType
    except ImportError as exc:  # pragma: no cover
        print("onnxruntime.quantization unavailable; skipping INT8.", exc)
        return

    quantize_dynamic(
        model_input=str(fp32_path),
        model_output=str(int8_path),
        weight_type=QuantType.QUInt8,
    )
    print(f"Exported INT8 ONNX -> {int8_path} ({int8_path.stat().st_size / 1024 / 1024:.2f} MB)")


def smoke_test(model_path: Path, class_names: list[str]) -> None:
    import onnxruntime as ort

    session = ort.InferenceSession(str(model_path), providers=["CPUExecutionProvider"])
    dummy = np.random.randn(1, 3, 128, 128).astype(np.float32)
    outputs = session.run(None, {"input": dummy})
    logits = outputs[0]
    assert logits.shape == (1, len(class_names)), f"Unexpected output shape {logits.shape}"
    probs = torch.softmax(torch.from_numpy(logits), dim=1)[0]
    top_idx = int(torch.argmax(probs))
    print(f"Smoke test OK ({model_path.name}). Top class: {class_names[top_idx]} @ {probs[top_idx]:.3f}")


def main() -> int:
    if not CKPT.exists():
        print(f"Checkpoint not found: {CKPT}")
        return 1

    model, class_names = load_model(CKPT)
    print(f"Loaded model with {len(class_names)} classes: {class_names}")

    export_onnx(model, ONNX_FP32)
    quantize_to_int8(ONNX_FP32, ONNX_INT8)

    with open(LABELS_OUT, "w") as f:
        json.dump(class_names, f, indent=2)
    print(f"Wrote labels -> {LABELS_OUT}")

    smoke_test(ONNX_FP32, class_names)
    if ONNX_INT8.exists():
        smoke_test(ONNX_INT8, class_names)

    return 0


if __name__ == "__main__":
    sys.exit(main())
