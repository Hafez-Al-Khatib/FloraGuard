"""Evaluate a YOLO detector — the ACCURACY GATE for sub-project B.

Reports standard fine mAP@50 (ultralytics) plus a GROUP-collapsed mAP@50 (each
predicted/GT box remapped to its coarse group), which is the number that gates
deployment: the per-plant diagnosis must not be weak. Gate defaults mirror the
plan (group >= 0.55, fine >= 0.35).

    python ml/detect/eval_detector.py \
        --weights ml/runs/detect/train/weights/best.pt \
        --data datasets/plantdoc_yolo/data.yaml --split test
"""
from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

import numpy as np
import yaml
from ultralytics import YOLO

sys.path.insert(0, os.path.dirname(__file__))
from labels import DET_CLASSES, det_group  # noqa: E402

GROUP_CLASSES = ["healthy", "blight", "leaf_spot", "viral", "pest"]


def _iou(a: np.ndarray, b: np.ndarray) -> float:
    ix1, iy1 = max(a[0], b[0]), max(a[1], b[1])
    ix2, iy2 = min(a[2], b[2]), min(a[3], b[3])
    iw, ih = max(0.0, ix2 - ix1), max(0.0, iy2 - iy1)
    inter = iw * ih
    ua = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - inter
    return inter / ua if ua > 0 else 0.0


def _ap(confs: list[float], tps: list[int], n_gt: int) -> float:
    """All-point AP from a class's detections (sorted internally) and GT count."""
    if n_gt == 0:
        return float("nan")
    order = np.argsort(-np.array(confs))
    tp = np.array(tps)[order]
    fp = 1 - tp
    tp_cum, fp_cum = np.cumsum(tp), np.cumsum(fp)
    rec = tp_cum / n_gt
    prec = tp_cum / np.maximum(tp_cum + fp_cum, 1e-9)
    # All-point interpolation.
    mrec = np.concatenate(([0.0], rec, [1.0]))
    mpre = np.concatenate(([0.0], prec, [0.0]))
    for i in range(len(mpre) - 1, 0, -1):
        mpre[i - 1] = max(mpre[i - 1], mpre[i])
    idx = np.where(mrec[1:] != mrec[:-1])[0]
    return float(np.sum((mrec[idx + 1] - mrec[idx]) * mpre[idx + 1]))


def _load_gt(label_path: Path, w: int, h: int) -> list[tuple[int, np.ndarray]]:
    out = []
    if not label_path.exists():
        return out
    for ln in label_path.read_text().splitlines():
        p = ln.split()
        if len(p) != 5:
            continue
        c = int(p[0]); cx, cy, bw, bh = (float(x) for x in p[1:])
        out.append((c, np.array([(cx - bw / 2) * w, (cy - bh / 2) * h,
                                 (cx + bw / 2) * w, (cy + bh / 2) * h])))
    return out


def _group_nms(boxes: list[np.ndarray], confs: list[float], iou_thres: float = 0.5):
    """Greedy NMS within one (remapped) class. Returns (box, conf) kept, high→low.

    Essential after a class remap: two fine boxes on the same object become the
    same group and must be merged, else the extra one is a false positive."""
    order = sorted(range(len(confs)), key=lambda i: -confs[i])
    kept = []
    for i in order:
        if all(_iou(boxes[i], boxes[j]) < iou_thres for j, _ in kept):
            kept.append((i, confs[i]))
    return [(boxes[i], c) for i, c in kept]


def _map_at50(model, images: list[Path], labels_dir: Path,
              classes: list[str], remap) -> float:
    """Custom mAP@50 over `classes`, remapping DET_CLASSES idx via `remap`."""
    from PIL import Image
    dets = {c: {"conf": [], "tp": []} for c in classes}
    n_gt = {c: 0 for c in classes}
    for img_path in images:
        w, h = Image.open(img_path).size
        gt = _load_gt(labels_dir / (img_path.stem + ".txt"), w, h)
        gt_by = {c: [] for c in classes}
        for cidx, box in gt:
            gc = remap(cidx)
            gt_by[gc].append([box, False]); n_gt[gc] += 1
        res = model.predict(str(img_path), conf=0.001, iou=0.6, verbose=False)[0]
        # Group predictions by remapped class, then NMS within each so co-located
        # boxes that collapsed to the same class don't double-count.
        by_cls: dict[str, list] = {c: [] for c in classes}
        for b in res.boxes:
            gc = remap(int(b.cls[0]))
            by_cls[gc].append((float(b.conf[0]), b.xyxy[0].cpu().numpy()))
        for gc in classes:
            if not by_cls[gc]:
                continue
            confs = [c for c, _ in by_cls[gc]]
            boxes = [bx for _, bx in by_cls[gc]]
            for box, conf in _group_nms(boxes, confs):
                best_iou, best_j = 0.0, -1
                for j, (gbox, used) in enumerate(gt_by[gc]):
                    if used:
                        continue
                    i = _iou(box, gbox)
                    if i > best_iou:
                        best_iou, best_j = i, j
                tp = 1 if best_iou >= 0.5 and best_j >= 0 else 0
                if tp:
                    gt_by[gc][best_j][1] = True
                dets[gc]["conf"].append(conf); dets[gc]["tp"].append(tp)
    per_class = {c: _ap(dets[c]["conf"], dets[c]["tp"], n_gt[c]) for c in classes}
    aps = [a for a in per_class.values() if not np.isnan(a)]
    return (float(np.mean(aps)) if aps else 0.0), per_class


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--weights", required=True)
    ap.add_argument("--data", required=True)
    ap.add_argument("--split", default="test")
    ap.add_argument("--group-gate", type=float, default=0.55)
    ap.add_argument("--fine-gate", type=float, default=0.35)
    args = ap.parse_args()

    model = YOLO(args.weights)
    # Standard fine mAP via ultralytics.
    metrics = model.val(data=args.data, split=args.split, verbose=False)
    fine_map = float(metrics.box.map50)

    cfg = yaml.safe_load(Path(args.data).read_text())
    root = Path(cfg["path"])
    images = sorted((root / "images" / args.split).glob("*"))
    labels_dir = root / "labels" / args.split

    group_map, group_ap = _map_at50(
        model, images, labels_dir, GROUP_CLASSES,
        lambda cidx: det_group(DET_CLASSES[cidx]))
    # Sanity cross-check: my own fine mAP should track ultralytics' — if it does,
    # the (same-method) group number is trustworthy.
    my_fine, _ = _map_at50(model, images, labels_dir, DET_CLASSES, lambda cidx: DET_CLASSES[cidx])

    print(f"\n{'':22s} mAP@50")
    print(f"{'fine (ultralytics)':22s} {fine_map:.3f}   (gate >= {args.fine_gate})")
    print(f"{'fine (self-check)':22s} {my_fine:.3f}   (should ~match above)")
    print(f"{'group (5-class)':22s} {group_map:.3f}   (gate >= {args.group_gate})")
    print("\nper-group AP@50:")
    for g in GROUP_CLASSES:
        v = group_ap[g]
        print(f"  {g:12s} {'n/a' if v != v else f'{v:.3f}'}")
    ok = group_map >= args.group_gate and fine_map >= args.fine_gate
    print(f"\nGATE: {'PASS — proceed to deploy the detector' if ok else 'FAIL — do NOT ship; iterate (bigger model / more data / captures)'}")
    return 0 if ok else 2


if __name__ == "__main__":
    raise SystemExit(main())
