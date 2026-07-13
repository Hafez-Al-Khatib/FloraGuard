"""Convert PlantDoc's VOC-XML bounding boxes to a YOLO dataset.

PlantDoc's detection release ships images + Pascal-VOC XML annotations. This
walks a source tree for *.xml, maps each object's free-text class to our
DET_CLASSES (dropping other crops), writes YOLO `class cx cy w h` (normalized)
label files with Windows-safe names, splits train/val/test, and emits data.yaml.

    python ml/detect/plantdoc_to_yolo.py \
        --src datasets/plantdoc_detect \
        --out datasets/plantdoc_yolo --val-frac 0.15 --test-frac 0.1
"""
from __future__ import annotations

import argparse
import os
import random
import re
import shutil
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

sys.path.insert(0, os.path.dirname(__file__))
from labels import DET_CLASSES, plantdoc_to_det  # noqa: E402

_IMG_EXT = (".jpg", ".jpeg", ".png", ".bmp", ".webp", ".JPG", ".JPEG", ".PNG")
_CLASS_IDX = {c: i for i, c in enumerate(DET_CLASSES)}


def _safe(name: str) -> str:
    """Filesystem-safe base name (PlantDoc names carry ?%: from scraped URLs)."""
    return re.sub(r"[^A-Za-z0-9._-]+", "_", name)


def _find_image(xml_path: Path) -> Path | None:
    stem = xml_path.with_suffix("")
    for ext in _IMG_EXT:
        cand = Path(str(stem) + ext)
        if cand.exists():
            return cand
    # Fall back to the <filename> tag, resolved next to the XML.
    try:
        fn = ET.parse(xml_path).getroot().findtext("filename")
    except ET.ParseError:
        return None
    if fn:
        cand = xml_path.parent / fn
        if cand.exists():
            return cand
    return None


def _convert_one(xml_path: Path) -> tuple[Path, list[str]] | None:
    """Return (image_path, yolo_lines) or None if unparseable/unmapped/empty."""
    try:
        root = ET.parse(xml_path).getroot()
    except ET.ParseError:
        return None
    size = root.find("size")
    if size is None:
        return None
    w = float(size.findtext("width") or 0)
    h = float(size.findtext("height") or 0)
    if w <= 0 or h <= 0:
        return None
    lines: list[str] = []
    for obj in root.findall("object"):
        det = plantdoc_to_det(obj.findtext("name") or "")
        if det is None:
            continue
        bb = obj.find("bndbox")
        if bb is None:
            continue
        x1 = float(bb.findtext("xmin") or 0); y1 = float(bb.findtext("ymin") or 0)
        x2 = float(bb.findtext("xmax") or 0); y2 = float(bb.findtext("ymax") or 0)
        x1, x2 = sorted((max(0.0, x1), min(w, x2)))
        y1, y2 = sorted((max(0.0, y1), min(h, y2)))
        if x2 <= x1 or y2 <= y1:
            continue
        cx, cy = (x1 + x2) / 2 / w, (y1 + y2) / 2 / h
        bw, bh = (x2 - x1) / w, (y2 - y1) / h
        lines.append(f"{_CLASS_IDX[det]} {cx:.6f} {cy:.6f} {bw:.6f} {bh:.6f}")
    if not lines:
        return None
    img = _find_image(xml_path)
    return (img, lines) if img else None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", type=Path, required=True, help="dir of images + VOC .xml")
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--val-frac", type=float, default=0.15)
    ap.add_argument("--test-frac", type=float, default=0.10)
    ap.add_argument("--seed", type=int, default=1337)
    args = ap.parse_args()

    xmls = list(args.src.rglob("*.xml"))
    if not xmls:
        raise SystemExit(f"no .xml annotations under {args.src}")
    converted = [c for c in (_convert_one(x) for x in xmls) if c]
    if not converted:
        raise SystemExit("no boxes mapped to our crops — check PLANTDOC_TO_DET names")

    rng = random.Random(args.seed)
    rng.shuffle(converted)
    n = len(converted)
    n_test = int(n * args.test_frac)
    n_val = int(n * args.val_frac)
    splits = {
        "test": converted[:n_test],
        "val": converted[n_test:n_test + n_val],
        "train": converted[n_test + n_val:],
    }
    counts = {c: 0 for c in DET_CLASSES}
    for split, items in splits.items():
        (args.out / "images" / split).mkdir(parents=True, exist_ok=True)
        (args.out / "labels" / split).mkdir(parents=True, exist_ok=True)
        for i, (img, lines) in enumerate(items):
            base = f"{split}_{i:05d}"
            shutil.copy2(img, args.out / "images" / split / (base + img.suffix.lower()))
            (args.out / "labels" / split / (base + ".txt")).write_text("\n".join(lines))
            for ln in lines:
                counts[DET_CLASSES[int(ln.split()[0])]] += 1

    data_yaml = args.out / "data.yaml"
    data_yaml.write_text(
        f"path: {args.out.resolve().as_posix()}\n"
        "train: images/train\nval: images/val\ntest: images/test\n"
        f"nc: {len(DET_CLASSES)}\n"
        "names: [" + ", ".join(f"'{c}'" for c in DET_CLASSES) + "]\n"
    )
    print(f"images: train={len(splits['train'])} val={len(splits['val'])} test={len(splits['test'])}")
    print("boxes per class:")
    for c in DET_CLASSES:
        print(f"  {c:46s} {counts[c]}")
    print(f"\ndata.yaml -> {data_yaml}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
