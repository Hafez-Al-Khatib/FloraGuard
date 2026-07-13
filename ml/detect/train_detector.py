"""Train a YOLO detector on the PlantDoc-YOLO dataset (Colab GPU recommended).

    python ml/detect/train_detector.py \
        --data datasets/plantdoc_yolo/data.yaml \
        --model yolov8n.pt --epochs 120 --imgsz 640 --out ml/runs/detect

Bigger backbones (yolov8s/m) are the first lever if the accuracy gate fails.
"""
from __future__ import annotations

import argparse
from pathlib import Path

from ultralytics import YOLO


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", required=True, help="path to data.yaml")
    ap.add_argument("--model", default="yolov8n.pt", help="yolov8n/s/m or v11 .pt")
    ap.add_argument("--epochs", type=int, default=120)
    ap.add_argument("--imgsz", type=int, default=640)
    ap.add_argument("--batch", type=int, default=16)
    ap.add_argument("--out", default="ml/runs/detect")
    args = ap.parse_args()

    model = YOLO(args.model)
    model.train(
        data=args.data, epochs=args.epochs, imgsz=args.imgsz, batch=args.batch,
        project=args.out, name="train", exist_ok=True,
        # Small dataset → lean on augmentation.
        hsv_h=0.015, hsv_s=0.7, hsv_v=0.4, degrees=10, translate=0.1,
        scale=0.5, fliplr=0.5, mosaic=1.0,
    )
    best = Path(args.out) / "train" / "weights" / "best.pt"
    print(f"\nbest weights -> {best}")
    print("Next: python ml/detect/eval_detector.py --weights", best,
          "--data", args.data, "--split test")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
