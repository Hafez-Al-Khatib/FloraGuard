"""Export the trained YOLO detector to ONNX for the edge server.

Run only after the accuracy gate passes (eval_detector.py). Produces
detector.onnx + detector_labels.json in the edge models dir; the edge auto-uses
the detector when the file is present.

    python ml/detect/export_detector.py \
        --weights ml/runs/detect/train/weights/best.pt --out edge-server/app/models
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
from pathlib import Path

from ultralytics import YOLO

sys.path.insert(0, os.path.dirname(__file__))
from labels import DET_CLASSES  # noqa: E402


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--weights", required=True)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--imgsz", type=int, default=640)
    args = ap.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)

    onnx_path = YOLO(args.weights).export(format="onnx", imgsz=args.imgsz, opset=13)
    dst = args.out / "detector.onnx"
    shutil.copy2(onnx_path, dst)
    (args.out / "detector_labels.json").write_text(json.dumps(DET_CLASSES, indent=2))
    print(f"detector -> {dst} ({dst.stat().st_size / 1e6:.1f} MB)")
    print(f"labels   -> {args.out / 'detector_labels.json'} ({len(DET_CLASSES)} classes)")
    print("The edge server auto-enables per-plant detection when this file exists.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
