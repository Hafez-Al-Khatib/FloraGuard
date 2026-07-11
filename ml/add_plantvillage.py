"""Merge PlantVillage (lab) images into an existing pv15 split.

Colab/GPU can afford the full 15-class PlantVillage on top of PlantDoc's field
images, which restores the 3 classes PlantDoc lacks (Potato-healthy, Target-Spot,
Spider-mites) and adds thousands of examples. The lab images are only useful
because ml/augment.py degrades them to look like field/ESP32-CAM captures.

Images are written under the EXACT PlantVillage label folder names (matched to
your labels.json by canonical form), so class names stay compatible with the
edge server's TreatmentDB. Only train/ and val/ are touched — the PlantDoc field
test/ split is left alone so evaluation stays an honest field measurement.

    python ml/add_plantvillage.py \
        --pv-src datasets/plantvillage/raw/color \
        --into datasets/pv15 \
        --labels edge-server/app/models/plantvillage_labels.json \
        --per-class 400
"""
from __future__ import annotations

import argparse
import json
import random
import re
import shutil
from pathlib import Path

_IMG_EXT = {".jpg", ".jpeg", ".png", ".bmp", ".webp"}


def canon(s: str) -> str:
    return re.sub(r"[^a-z0-9]+", "_", s.lower()).strip("_")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--pv-src", type=Path, required=True,
                    help="PlantVillage dir of <label>/<images> (e.g. raw/color)")
    ap.add_argument("--into", type=Path, required=True, help="existing pv15 split root")
    ap.add_argument("--labels", type=Path, required=True,
                    help="plantvillage_labels.json — the exact label spelling to use")
    ap.add_argument("--per-class", type=int, default=400,
                    help="cap images per class (balances lab vs field, bounds time)")
    ap.add_argument("--val-frac", type=float, default=0.15)
    ap.add_argument("--seed", type=int, default=1337)
    args = ap.parse_args()

    labels = json.loads(args.labels.read_text())
    by_canon = {canon(l): l for l in labels}
    rng = random.Random(args.seed)

    added: dict[str, int] = {}
    for d in sorted(p for p in args.pv_src.iterdir() if p.is_dir()):
        label = by_canon.get(canon(d.name))
        if label is None:
            continue  # a PlantVillage class outside our 15
        imgs = [p for p in d.rglob("*") if p.suffix.lower() in _IMG_EXT]
        rng.shuffle(imgs)
        imgs = imgs[:args.per_class]
        n_val = int(len(imgs) * args.val_frac)
        for i, img in enumerate(imgs):
            split = "val" if i < n_val else "train"
            out = args.into / split / label
            out.mkdir(parents=True, exist_ok=True)
            shutil.copy2(img, out / f"{label}_pv_{i:05d}{img.suffix.lower()}")
        added[label] = len(imgs)

    for label in labels:
        print(f"{label:46s} +{added.get(label, 0)}")
    print(f"\nmerged {len(added)}/{len(labels)} PlantVillage classes into {args.into}")
    if len(added) < len(labels):
        missing = [l for l in labels if l not in added]
        print(f"not found in --pv-src (check folder names): {missing}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
