"""Convert PlantDoc detection data to a YOLO dataset in OUR fixed class order.

Auto-detects the input format so it works with whatever you downloaded:
  - Pascal VOC   : a tree of images + *.xml
  - Roboflow YOLO: split dirs (train/valid/test) each with images/ + labels/ and
                   a data.yaml listing class names
  - COCO         : a *_annotations.coco.json (Roboflow "COCO" export)

Every box is remapped to our 15 tomato/potato/pepper classes (others dropped),
written normalized `class cx cy w h`, split train/val/test, with a data.yaml
whose `names` are exactly DET_CLASSES — so training, export, and the edge all
agree on class order. Filenames are made Windows-safe.

    python ml/detect/plantdoc_to_yolo.py --src datasets/plantdoc_detect --out datasets/plantdoc_yolo
"""
from __future__ import annotations

import argparse
import json
import os
import random
import re
import shutil
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

sys.path.insert(0, os.path.dirname(__file__))
from labels import DET_CLASSES, canon, plantdoc_to_det  # noqa: E402

_IMG_EXT = (".jpg", ".jpeg", ".png", ".bmp", ".webp")
_CLASS_IDX = {c: i for i, c in enumerate(DET_CLASSES)}
# A YOLO box record: (our_class_idx, cx, cy, w, h) all normalized 0-1.
Record = "tuple[Path, list[tuple[int, float, float, float, float]]]"


def _safe(name: str) -> str:
    return re.sub(r"[^A-Za-z0-9._-]+", "_", name)


def _clip_norm(x1, y1, x2, y2, w, h):
    x1, x2 = sorted((max(0.0, x1), min(w, x2)))
    y1, y2 = sorted((max(0.0, y1), min(h, y2)))
    if x2 <= x1 or y2 <= y1 or w <= 0 or h <= 0:
        return None
    return ((x1 + x2) / 2 / w, (y1 + y2) / 2 / h, (x2 - x1) / w, (y2 - y1) / h)


def _find_image(stem: Path) -> Path | None:
    for ext in _IMG_EXT:
        for c in (Path(str(stem) + ext), Path(str(stem) + ext.upper())):
            if c.exists():
                return c
    return None


# ── VOC ───────────────────────────────────────────────────────────────────────
def _records_voc(src: Path) -> list:
    out = []
    for xml in src.rglob("*.xml"):
        try:
            root = ET.parse(xml).getroot()
        except ET.ParseError:
            continue
        size = root.find("size")
        if size is None:
            continue
        w = float(size.findtext("width") or 0); h = float(size.findtext("height") or 0)
        boxes = []
        for obj in root.findall("object"):
            det = plantdoc_to_det(obj.findtext("name") or "")
            bb = obj.find("bndbox")
            if det is None or bb is None:
                continue
            norm = _clip_norm(float(bb.findtext("xmin") or 0), float(bb.findtext("ymin") or 0),
                              float(bb.findtext("xmax") or 0), float(bb.findtext("ymax") or 0), w, h)
            if norm:
                boxes.append((_CLASS_IDX[det], *norm))
        img = _find_image(xml.with_suffix("")) or (
            xml.parent / (root.findtext("filename") or "") if root.findtext("filename") else None)
        if boxes and img and img.exists():
            out.append((img, boxes))
    return out


# ── Roboflow YOLO ─────────────────────────────────────────────────────────────
def _yaml_names(path: Path) -> list[str]:
    """Minimal `names:` reader (avoids a yaml dep here)."""
    text = path.read_text(encoding="utf-8", errors="ignore")
    m = re.search(r"names:\s*\[([^\]]*)\]", text)
    if m:
        return [n.strip().strip("'\"") for n in m.group(1).split(",") if n.strip()]
    names, capture = [], False
    for ln in text.splitlines():
        if re.match(r"\s*names:\s*$", ln):
            capture = True; continue
        if capture:
            mm = re.match(r"\s*-\s*(.+)$", ln) or re.match(r"\s*\d+:\s*(.+)$", ln)
            if mm:
                names.append(mm.group(1).strip().strip("'\""))
            elif ln.strip() and not ln.startswith((" ", "\t", "-")):
                break
    return names


def _records_yolo(src: Path, data_yaml: Path) -> list:
    names = _yaml_names(data_yaml)
    if not names:
        raise SystemExit(f"could not read class names from {data_yaml}")
    # src class index → our class index (or None to drop).
    remap = {}
    for i, nm in enumerate(names):
        det = plantdoc_to_det(nm) or (nm if canon(nm) in {canon(c) for c in DET_CLASSES} else None)
        if det in _CLASS_IDX:
            remap[i] = _CLASS_IDX[det]
    out = []
    for lbl in src.rglob("*.txt"):
        if lbl.name.lower() in ("classes.txt", "readme.txt"):
            continue
        boxes = []
        for line in lbl.read_text().splitlines():
            p = line.split()
            if len(p) < 5:
                continue
            src_idx = int(float(p[0]))
            if src_idx in remap:
                boxes.append((remap[src_idx], float(p[1]), float(p[2]), float(p[3]), float(p[4])))
        if not boxes:
            continue
        # images/ sits beside labels/ in Roboflow exports.
        img_dir = Path(str(lbl.parent).replace("labels", "images"))
        img = _find_image(img_dir / lbl.stem)
        if img:
            out.append((img, boxes))
    return out


# ── COCO ──────────────────────────────────────────────────────────────────────
def _records_coco(src: Path, coco_json: Path) -> list:
    data = json.loads(coco_json.read_text())
    cat_name = {c["id"]: c["name"] for c in data.get("categories", [])}
    img_meta = {im["id"]: im for im in data.get("images", [])}
    by_img: dict[int, list] = {}
    for a in data.get("annotations", []):
        det = plantdoc_to_det(cat_name.get(a["category_id"], ""))
        if det not in _CLASS_IDX:
            continue
        by_img.setdefault(a["image_id"], []).append((det, a["bbox"]))  # bbox=[x,y,w,h]
    out = []
    for img_id, anns in by_img.items():
        im = img_meta.get(img_id)
        if not im:
            continue
        w, h = float(im["width"]), float(im["height"])
        boxes = []
        for det, (x, y, bw, bh) in anns:
            norm = _clip_norm(x, y, x + bw, y + bh, w, h)
            if norm:
                boxes.append((_CLASS_IDX[det], *norm))
        img = coco_json.parent / im["file_name"]
        if boxes and img.exists():
            out.append((img, boxes))
    return out


def _collect(src: Path) -> list:
    if list(src.rglob("*.xml")):
        print("detected format: Pascal VOC (*.xml)")
        return _records_voc(src)
    yamls = list(src.rglob("data.yaml")) + list(src.rglob("data.yml"))
    if yamls:
        print(f"detected format: Roboflow YOLO ({yamls[0]})")
        return _records_yolo(src, yamls[0])
    cocos = [j for j in src.rglob("*.json") if "coco" in j.name.lower() or "annotation" in j.name.lower()]
    if cocos:
        print(f"detected format: COCO ({cocos[0]})")
        return _records_coco(src, cocos[0])
    raise SystemExit(
        f"no VOC (*.xml), Roboflow YOLO (data.yaml), or COCO (*.json) found under {src}.\n"
        "Get PlantDoc detection data from Roboflow Universe (search 'PlantDoc'),\n"
        "Download → format YOLOv8 (or COCO), unzip into the --src folder.")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", type=Path, required=True)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--val-frac", type=float, default=0.15)
    ap.add_argument("--test-frac", type=float, default=0.10)
    ap.add_argument("--seed", type=int, default=1337)
    args = ap.parse_args()

    records = _collect(args.src)
    if not records:
        raise SystemExit("found the dataset but mapped 0 boxes to our crops — "
                         "check the class names against ml/detect/labels.py PLANTDOC_TO_DET")

    rng = random.Random(args.seed)
    rng.shuffle(records)
    n = len(records)
    n_test = int(n * args.test_frac); n_val = int(n * args.val_frac)
    splits = {"test": records[:n_test], "val": records[n_test:n_test + n_val],
              "train": records[n_test + n_val:]}
    counts = {c: 0 for c in DET_CLASSES}
    for split, items in splits.items():
        (args.out / "images" / split).mkdir(parents=True, exist_ok=True)
        (args.out / "labels" / split).mkdir(parents=True, exist_ok=True)
        for i, (img, boxes) in enumerate(items):
            base = f"{split}_{i:05d}"
            shutil.copy2(img, args.out / "images" / split / (base + img.suffix.lower()))
            (args.out / "labels" / split / (base + ".txt")).write_text(
                "\n".join(f"{c} {cx:.6f} {cy:.6f} {bw:.6f} {bh:.6f}" for c, cx, cy, bw, bh in boxes))
            for c, *_ in boxes:
                counts[DET_CLASSES[c]] += 1

    (args.out / "data.yaml").write_text(
        f"path: {args.out.resolve().as_posix()}\n"
        "train: images/train\nval: images/val\ntest: images/test\n"
        f"nc: {len(DET_CLASSES)}\n"
        "names: [" + ", ".join(f"'{c}'" for c in DET_CLASSES) + "]\n")
    print(f"images: train={len(splits['train'])} val={len(splits['val'])} test={len(splits['test'])}")
    print("boxes per class:")
    for c in DET_CLASSES:
        print(f"  {c:46s} {counts[c]}")
    print(f"\ndata.yaml -> {args.out / 'data.yaml'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
