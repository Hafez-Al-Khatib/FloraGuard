"""Evaluate an exported ONNX model on a held-out (ideally field) test set.

Reports overall accuracy, macro-F1, and a per-class breakdown — the numbers that
actually matter for the lab->field gap (a high PlantVillage score means nothing
here). Run it on both the FP32 and INT8 exports to confirm quantization didn't
cost you accuracy.

    python ml/evaluate.py \
        --model edge-server/app/models/field_mnv3_15cls_int8.onnx \
        --labels edge-server/app/models/field_labels.json \
        --data datasets/prepared/val --img-size 224
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np
import onnxruntime as ort
from PIL import Image
from sklearn.metrics import classification_report, f1_score

from export_onnx import preprocess  # identical eval preprocessing

_IMG_EXT = {".jpg", ".jpeg", ".png", ".bmp", ".webp"}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", type=Path, required=True)
    ap.add_argument("--labels", type=Path, required=True)
    ap.add_argument("--data", type=Path, required=True, help="ImageFolder: <class>/<images>")
    ap.add_argument("--img-size", type=int, default=224)
    args = ap.parse_args()

    labels = json.loads(args.labels.read_text())
    index = {name: i for i, name in enumerate(labels)}
    sess = ort.InferenceSession(str(args.model), providers=["CPUExecutionProvider"])
    inp = sess.get_inputs()[0].name

    gts, preds, skipped = [], [], 0
    for class_dir in sorted(p for p in args.data.iterdir() if p.is_dir()):
        if class_dir.name not in index:
            skipped += 1
            continue
        y = index[class_dir.name]
        for img in (p for p in class_dir.rglob("*") if p.suffix.lower() in _IMG_EXT):
            try:
                x = preprocess(img, args.img_size)[None]
            except Exception:
                continue
            out = sess.run(None, {inp: x})[0][0]
            preds.append(int(np.argmax(out)))
            gts.append(y)

    if not gts:
        raise SystemExit("no evaluable images — do the data class names match labels.json?")
    gts, preds = np.array(gts), np.array(preds)
    print(f"model: {args.model.name}   images: {len(gts)}   (skipped {skipped} unmatched class dirs)")
    print(f"accuracy: {(gts == preds).mean():.3f}   macro-F1: {f1_score(gts, preds, average='macro'):.3f}\n")
    present = sorted(set(gts.tolist()) | set(preds.tolist()))
    print(classification_report(gts, preds, labels=present,
                                target_names=[labels[i] for i in present], zero_division=0))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
