"""Remap PlantDoc (field images) into the 15 PlantVillage label space.

This makes the two models directly comparable on the SAME field test images:
  - baseline: the current PlantVillage-trained model, evaluated on PlantDoc test
  - new     : a model trained on PlantDoc train, evaluated on PlantDoc test

PlantDoc class folders use free-text names ("Tomato leaf late blight"); we map
them onto the exact PlantVillage label strings the edge server already uses
(plantvillage_labels.json). Classes with no clean PlantDoc counterpart
(e.g. Tomato Target Spot) are simply absent from the mapped set.

Outputs, from --src <plantdoc-root> (which contains train/ and test/):
  <out>/train/<pv_label>/*   (PlantDoc train, minus val holdout)
  <out>/val/<pv_label>/*     (val holdout from PlantDoc train)
  <out>/test/<pv_label>/*    (PlantDoc test)

    python ml/plantdoc_to_pv.py --src datasets/plantdoc --out datasets/pv15
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
    return re.sub(r"[^a-z0-9]+", "_", name.lower()).strip("_")


# PlantVillage label  ->  canonicalised PlantDoc folder name(s).
# Kept explicit (not fuzzy) so a mismatch is visible, not silently wrong.
PV_FROM_PLANTDOC: dict[str, list[str]] = {
    "Pepper__bell___healthy": ["bell_pepper_leaf"],
    "Pepper__bell___Bacterial_spot": ["bell_pepper_leaf_spot"],
    "Potato___Early_blight": ["potato_leaf_early_blight"],
    "Potato___Late_blight": ["potato_leaf_late_blight"],
    "Potato___healthy": ["potato_leaf"],
    "Tomato_Bacterial_spot": ["tomato_leaf_bacterial_spot"],
    "Tomato_Early_blight": ["tomato_early_blight_leaf"],
    "Tomato_Late_blight": ["tomato_leaf_late_blight"],
    "Tomato_Leaf_Mold": ["tomato_mold_leaf"],
    "Tomato_Septoria_leaf_spot": ["tomato_septoria_leaf_spot"],
    "Tomato_Spider_mites_Two_spotted_spider_mite": ["tomato_two_spotted_spider_mites_leaf"],
    "Tomato__Tomato_YellowLeaf__Curl_Virus": ["tomato_leaf_yellow_virus"],
    "Tomato__Tomato_mosaic_virus": ["tomato_leaf_mosaic_virus"],
    "Tomato_healthy": ["tomato_leaf"],
    # Tomato__Target_Spot: no clean PlantDoc counterpart -> intentionally omitted.
}

# Reverse index: canon(plantdoc folder) -> pv label
_PD_TO_PV = {pd: pv for pv, pds in PV_FROM_PLANTDOC.items() for pd in pds}


def copy_split(src_dir: Path, dst_root: Path, split_name: str,
               rng: random.Random | None = None, val_frac: float = 0.0,
               val_root: Path | None = None) -> dict[str, int]:
    """Copy one PlantDoc split dir into PV-labelled folders. If val_frac>0,
    hold out that fraction into val_root instead."""
    counts: dict[str, int] = defaultdict(int)
    for class_dir in sorted(p for p in src_dir.iterdir() if p.is_dir()):
        pv = _PD_TO_PV.get(canon(class_dir.name))
        if pv is None:
            continue
        imgs = [p for p in class_dir.rglob("*") if p.suffix.lower() in _IMG_EXT]
        if rng is not None:
            rng.shuffle(imgs)
        n_val = int(len(imgs) * val_frac)
        for i, img in enumerate(imgs):
            to_val = val_root is not None and i < n_val
            root = val_root if to_val else dst_root
            out_dir = root / pv
            out_dir.mkdir(parents=True, exist_ok=True)
            shutil.copy2(img, out_dir / f"{pv}_{split_name}_{i:05d}{img.suffix.lower()}")
            counts[pv] += 1
    return counts


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", type=Path, required=True, help="PlantDoc root with train/ and test/")
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--val-frac", type=float, default=0.15)
    ap.add_argument("--seed", type=int, default=1337)
    args = ap.parse_args()

    train_src = args.src / "train"
    test_src = args.src / "test"
    if not train_src.is_dir() or not test_src.is_dir():
        # Some PlantDoc mirrors use TRAIN/TEST or a flat layout — surface it.
        raise SystemExit(f"expected {train_src} and {test_src}; found: "
                         f"{[p.name for p in args.src.iterdir()]}")

    rng = random.Random(args.seed)
    tr = copy_split(train_src, args.out / "train", "tr", rng, args.val_frac, args.out / "val")
    te = copy_split(test_src, args.out / "test", "te")

    all_pv = sorted(set(tr) | set(te) | set(PV_FROM_PLANTDOC))
    print(f"{'PV label':46s} {'train':>6s} {'test':>5s}")
    for pv in all_pv:
        mark = "" if pv in tr or pv in te else "   <-- NO DATA (unmapped/missing)"
        print(f"{pv:46s} {tr.get(pv,0):6d} {te.get(pv,0):5d}{mark}")
    print(f"\nmapped {len(set(tr)|set(te))}/15 PV classes -> {args.out}")

    # Surface PlantDoc folders we did NOT map, so nothing is silently dropped.
    seen = {canon(p.name) for p in train_src.iterdir() if p.is_dir()}
    unmapped = sorted(seen - set(_PD_TO_PV))
    if unmapped:
        print(f"\nPlantDoc classes not mapped (other crops / no PV label): {len(unmapped)}")
        for u in unmapped:
            print(f"  {u}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
