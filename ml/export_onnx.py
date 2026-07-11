"""Export the trained model to ONNX FP32 and *static* INT8.

This supersedes the old export_plantvillage_onnx.py, whose INT8 used
`quantize_dynamic` — dynamic quantization only accelerates Linear/RNN layers and
does almost nothing for a Conv-heavy net like MobileNet/ResNet, while still
risking accuracy. Static (calibrated) quantization quantizes the activations too
and is the correct choice for a CNN.

Calibration matters: point --calib-dir at REAL ESP32-CAM frames (or your field
val set), not clean lab images, so the activation ranges match deployment.

    python ml/export_onnx.py \
        --ckpt ml/runs/mnv3_field/best.pt \
        --calib-dir datasets/prepared/val \
        --out edge-server/app/models

Produces field_mnv3_<n>cls.onnx, field_mnv3_<n>cls_int8.onnx, and
field_labels.json in --out.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np
import onnxruntime as ort
import timm
import torch
from onnxruntime.quantization import CalibrationDataReader, QuantType, quantize_static
from PIL import Image

IMAGENET_MEAN = np.array([0.485, 0.456, 0.406], np.float32).reshape(3, 1, 1)
IMAGENET_STD = np.array([0.229, 0.224, 0.225], np.float32).reshape(3, 1, 1)
_IMG_EXT = {".jpg", ".jpeg", ".png", ".bmp", ".webp"}


def preprocess(path: Path, img_size: int) -> np.ndarray:
    img = Image.open(path).convert("RGB").resize((img_size, img_size), Image.BILINEAR)
    arr = np.asarray(img, np.float32).transpose(2, 0, 1) / 255.0
    return (arr - IMAGENET_MEAN) / IMAGENET_STD


class FolderCalibrationReader(CalibrationDataReader):
    """Feeds up to `limit` real images through the graph to calibrate INT8
    activation ranges."""

    def __init__(self, calib_dir: Path, input_name: str, img_size: int, limit: int = 300):
        files = [p for p in calib_dir.rglob("*") if p.suffix.lower() in _IMG_EXT]
        self.data = iter(
            {input_name: preprocess(p, img_size)[None]} for p in files[:limit]
        )

    def get_next(self):
        return next(self.data, None)


def export_fp32(ckpt: dict, path: Path) -> None:
    model = timm.create_model(ckpt["backbone"], pretrained=False, num_classes=len(ckpt["class_names"]))
    model.load_state_dict(ckpt["model_state"])
    model.eval()
    size = ckpt["img_size"]
    dummy = torch.randn(1, 3, size, size)
    torch.onnx.export(
        model, dummy, str(path), export_params=True, opset_version=13,
        do_constant_folding=True, input_names=["input"], output_names=["output"],
        dynamic_axes={"input": {0: "batch_size"}, "output": {0: "batch_size"}},
        dynamo=False,
    )
    print(f"FP32 -> {path} ({path.stat().st_size / 1e6:.2f} MB)")


def smoke(path: Path, labels: list[str], img_size: int) -> None:
    sess = ort.InferenceSession(str(path), providers=["CPUExecutionProvider"])
    x = np.random.randn(1, 3, img_size, img_size).astype(np.float32)
    out = sess.run(None, {sess.get_inputs()[0].name: x})[0]
    assert out.shape == (1, len(labels)), out.shape
    print(f"  smoke ok: {path.name} output {out.shape}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--ckpt", type=Path, required=True)
    ap.add_argument("--calib-dir", type=Path, required=True,
                    help="real cam frames / field val images for INT8 calibration")
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--calib-limit", type=int, default=300)
    ap.add_argument(
        "--quant", default="static",
        choices=["static", "dynamic", "fp16", "none"],
        help="static=calibrated INT8 (smallest, tiny loss); dynamic=weights-only "
             "INT8 (no calib, weak for CNNs); fp16=half precision (near-lossless, "
             "half size, limited CPU speedup); none=FP32 only",
    )
    ap.add_argument(
        "--exclude-nodes", nargs="*", default=None,
        help="static only: node names to keep in FP32 (mixed precision) — use for "
             "quantization-sensitive layers if static INT8 costs too much accuracy",
    )
    args = ap.parse_args()

    ckpt = torch.load(args.ckpt, map_location="cpu", weights_only=False)
    labels = ckpt["class_names"]
    img_size = ckpt["img_size"]
    n = len(labels)
    args.out.mkdir(parents=True, exist_ok=True)

    fp32 = args.out / f"field_mnv3_{n}cls.onnx"
    export_fp32(ckpt, fp32)
    smoke(fp32, labels, img_size)

    if args.quant == "static":
        out = args.out / f"field_mnv3_{n}cls_int8.onnx"
        reader = FolderCalibrationReader(args.calib_dir, "input", img_size, args.calib_limit)
        quantize_static(
            model_input=str(fp32), model_output=str(out),
            calibration_data_reader=reader,
            quant_format=ort.quantization.QuantFormat.QDQ,
            activation_type=QuantType.QUInt8, weight_type=QuantType.QInt8,
            per_channel=True, nodes_to_exclude=args.exclude_nodes or [],
        )
        kind = "INT8 static" + (" (mixed)" if args.exclude_nodes else "")
    elif args.quant == "dynamic":
        from onnxruntime.quantization import quantize_dynamic
        out = args.out / f"field_mnv3_{n}cls_int8dyn.onnx"
        quantize_dynamic(model_input=str(fp32), model_output=str(out), weight_type=QuantType.QInt8)
        kind = "INT8 dynamic"
    elif args.quant == "fp16":
        import onnx
        from onnxconverter_common import float16
        out = args.out / f"field_mnv3_{n}cls_fp16.onnx"
        # keep_io_types: inputs/outputs stay FP32 so the server preprocessing is unchanged.
        onnx.save(float16.convert_float_to_float16(onnx.load(str(fp32)), keep_io_types=True), str(out))
        kind = "FP16"
    else:  # none
        out = None

    if out is not None:
        print(f"{kind} -> {out} ({out.stat().st_size / 1e6:.2f} MB)")
        smoke(out, labels, img_size)

    (args.out / "field_labels.json").write_text(json.dumps(labels, indent=2))
    print(f"labels -> {args.out / 'field_labels.json'}")
    print("\nNext: point edge-server config at these files (see ml/README.md).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
