"""Assemble a training set from one or more class-foldered image sources.

Produces a clean ImageFolder layout:

    <out>/train/<class>/*.jpg
    <out>/val/<class>/*.jpg

Sources are directories laid out as `<src>/<class>/*.jpg` (PlantDoc's
classification split, PlantVillage, and your own captured ESP32-CAM frames all
fit this shape). Pass `--classes` to restrict to the crops you actually grow —
fewer classes means fewer confusions in the field. Class names are matched
case-insensitively after normalising separators, so `Tomato___Late_blight`,
`Tomato_Late_blight`, and `tomato late blight` merge into one class.

Example:
    python ml/prepare_data.py \
        --source datasets/plantdoc/train \
        --source datasets/plantvillage/color \
        --source datasets/my_cam_captures \
        --classes tomato_late_blight tomato_healthy pepper_bell_healthy \
        --val-frac 0.15 --out datasets/prepared
"""
from __future__ import annotations

import argparse
import random
import re
import shutil
from collections import defaultdict
from pathlib import Path

_IMG_EXT = {".jpg", ".jpeg", ".png", ".bmp", ".webp"}


def canon(name: str) -> str:
    """Canonical class key: lowercase, separators collapsed to single '_'."""
    return re.sub(r"[^a-z0-9]+", "_", name.lower()).strip("_")


def collect(sources: list[Path], allow: set[str] | None) -> dict[str, list[Path]]:
    buckets: dict[str, list[Path]] = defaultdict(list)
    for src in sources:
        if not src.is_dir():
            raise SystemExit(f"source not found: {src}")
        for class_dir in sorted(p for p in src.iterdir() if p.is_dir()):
            key = canon(class_dir.name)
            if allow is not None and key not in allow:
                continue
            imgs = [p for p in class_dir.rglob("*") if p.suffix.lower() in _IMG_EXT]
            buckets[key].extend(imgs)
    return buckets


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", action="append", required=True, type=Path,
                    help="repeatable; a dir of <class>/<images>")
    ap.add_argument("--classes", nargs="*", default=None,
                    help="allowlist of class names (canonicalised); omit for all")
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--val-frac", type=float, default=0.15)
    ap.add_argument("--seed", type=int, default=1337)
    ap.add_argument("--min-per-class", type=int, default=20,
                    help="warn if a class has fewer images than this")
    args = ap.parse_args()

    allow = {canon(c) for c in args.classes} if args.classes else None
    buckets = collect(args.source, allow)
    if not buckets:
        raise SystemExit("no images collected — check --source paths and --classes")

    rng = random.Random(args.seed)
    for split in ("train", "val"):
        for key in buckets:
            (args.out / split / key).mkdir(parents=True, exist_ok=True)

    total = 0
    print(f"{'class':40s} {'train':>7s} {'val':>5s}")
    for key, imgs in sorted(buckets.items()):
        rng.shuffle(imgs)
        n_val = max(1, int(len(imgs) * args.val_frac)) if len(imgs) > 1 else 0
        val, train = imgs[:n_val], imgs[n_val:]
        for split, group in (("train", train), ("val", val)):
            for i, p in enumerate(group):
                dst = args.out / split / key / f"{key}_{i:05d}{p.suffix.lower()}"
                shutil.copy2(p, dst)
        total += len(imgs)
        flag = "  <-- LOW" if len(imgs) < args.min_per_class else ""
        print(f"{key:40s} {len(train):7d} {n_val:5d}{flag}")

    print(f"\n{len(buckets)} classes, {total} images -> {args.out}")
    print("Class order (this is the label index order the model will learn):")
    for i, key in enumerate(sorted(buckets)):
        print(f"  {i:2d}  {key}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
