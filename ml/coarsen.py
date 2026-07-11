"""Collapse the 15 fine PlantVillage classes into 5 actionable disease groups.

The crop is already known from which node/camera the frame came from, so the
model does not need to identify the crop — only the *kind* of problem, which is
what drives the response. Grouping also merges the visually near-identical
classes the fine model kept confusing (potato early vs late blight, tomato
bacterial vs septoria vs target spot), which is where most of the 15-class
error was.

Groups (and why they're one bucket for response):
  healthy   — no action
  blight    — aggressive fungal/oomycete; fungicide + remove infected tissue
  leaf_spot — bacterial/fungal lesions; copper (bacterial) or fungicide (fungal)
  viral     — no chemical cure; rogue the plant, control insect vectors
  pest      — mite damage; miticide / insecticidal soap

Usage:
  # build a grouped ImageFolder from a pv15-style root (train/val/test of fine classes)
  python ml/coarsen.py build --src datasets/pv15 --out datasets/coarse5
"""
from __future__ import annotations

import argparse
import shutil
from pathlib import Path

GROUPS: dict[str, list[str]] = {
    "healthy": [
        "Pepper__bell___healthy",
        "Potato___healthy",
        "Tomato_healthy",
    ],
    "blight": [
        "Potato___Early_blight",
        "Potato___Late_blight",
        "Tomato_Early_blight",
        "Tomato_Late_blight",
    ],
    "leaf_spot": [
        "Pepper__bell___Bacterial_spot",
        "Tomato_Bacterial_spot",
        "Tomato_Septoria_leaf_spot",
        "Tomato__Target_Spot",
        "Tomato_Leaf_Mold",
    ],
    "viral": [
        "Tomato__Tomato_YellowLeaf__Curl_Virus",
        "Tomato__Tomato_mosaic_virus",
    ],
    "pest": [
        "Tomato_Spider_mites_Two_spotted_spider_mite",
    ],
}

FINE_TO_GROUP: dict[str, str] = {
    fine: group for group, fines in GROUPS.items() for fine in fines
}

# Deterministic label order for the grouped model (index = sorted group name).
GROUP_LABELS: list[str] = sorted(GROUPS)

_IMG_EXT = {".jpg", ".jpeg", ".png", ".bmp", ".webp"}


def coarse(fine_label: str) -> str | None:
    """Map a fine PlantVillage label to its group, or None if unknown."""
    return FINE_TO_GROUP.get(fine_label)


def build(src: Path, out: Path, splits: list[str]) -> None:
    for split in splits:
        split_dir = src / split
        if not split_dir.is_dir():
            continue
        counts: dict[str, int] = {g: 0 for g in GROUPS}
        for fine_dir in sorted(p for p in split_dir.iterdir() if p.is_dir()):
            group = coarse(fine_dir.name)
            if group is None:
                print(f"  [skip] {split}/{fine_dir.name}: not in any group")
                continue
            dst = out / split / group
            dst.mkdir(parents=True, exist_ok=True)
            for img in (p for p in fine_dir.rglob("*") if p.suffix.lower() in _IMG_EXT):
                shutil.copy2(img, dst / f"{group}_{counts[group]:05d}{img.suffix.lower()}")
                counts[group] += 1
        total = sum(counts.values())
        print(f"{split:6s}: " + "  ".join(f"{g}={counts[g]}" for g in GROUP_LABELS) + f"  (total {total})")


def main() -> int:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build", help="build a grouped ImageFolder from a pv15 root")
    b.add_argument("--src", type=Path, required=True)
    b.add_argument("--out", type=Path, required=True)
    b.add_argument("--splits", nargs="*", default=["train", "val", "test"])
    args = ap.parse_args()
    if args.cmd == "build":
        build(args.src, args.out, args.splits)
        print(f"\ngroups: {GROUP_LABELS}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
