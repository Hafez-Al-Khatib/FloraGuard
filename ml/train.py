"""Fine-tune a field-robust disease classifier.

Backbone default is MobileNetV3-Large: the best accuracy/latency trade-off for
Pi-5 CPU inference, and it quantizes to INT8 cleanly (unlike ViTs). The biggest
generalization lever is the INIT weights — pass --pretrained-ckpt with a
PDDD-PreTrain checkpoint (400k+ field images, 120 disease classes) instead of
plain ImageNet. Falls back to timm's ImageNet weights if none given.

    python ml/train.py \
        --data datasets/prepared \
        --pretrained-ckpt weights/pddd_mobilenetv3_large.pth \
        --epochs 40 --img-size 224 --out ml/runs/mnv3_field

Outputs `<out>/best.pt` (state dict + class_names + img_size) and
`<out>/labels.json`. Feed best.pt to ml/export_onnx.py.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np
import timm
import torch
import torch.nn as nn
from sklearn.metrics import f1_score
from torch.utils.data import DataLoader
from torchvision.datasets import ImageFolder
from tqdm import tqdm

from augment import build_eval_transform, build_train_transform


def load_pretrained_backbone(model: nn.Module, ckpt_path: Path) -> None:
    """Load matching backbone tensors from an external checkpoint (e.g. PDDD),
    skipping the classifier head (different class count) and any mismatches."""
    raw = torch.load(ckpt_path, map_location="cpu", weights_only=False)
    state = raw.get("model_state", raw.get("state_dict", raw))
    state = {k.replace("module.", ""): v for k, v in state.items()}
    tgt = model.state_dict()
    loaded, skipped = 0, 0
    for k, v in state.items():
        if k in tgt and tgt[k].shape == v.shape:
            tgt[k] = v
            loaded += 1
        else:
            skipped += 1
    model.load_state_dict(tgt)
    print(f"pretrained init: loaded {loaded} tensors, skipped {skipped} (head/mismatch)")


def run_epoch(model, loader, device, criterion, optimizer=None):
    train = optimizer is not None
    model.train(train)
    losses, preds, gts = [], [], []
    for x, y in tqdm(loader, leave=False):
        x, y = x.to(device), y.to(device)
        with torch.set_grad_enabled(train):
            out = model(x)
            loss = criterion(out, y)
            if train:
                optimizer.zero_grad()
                loss.backward()
                optimizer.step()
        losses.append(loss.item())
        preds.append(out.argmax(1).cpu().numpy())
        gts.append(y.cpu().numpy())
    preds, gts = np.concatenate(preds), np.concatenate(gts)
    macro_f1 = f1_score(gts, preds, average="macro")
    acc = (preds == gts).mean()
    return float(np.mean(losses)), float(acc), float(macro_f1)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", type=Path, required=True, help="ImageFolder root with train/ val/")
    ap.add_argument("--backbone", default="mobilenetv3_large_100")
    ap.add_argument("--pretrained-ckpt", type=Path, default=None)
    ap.add_argument("--img-size", type=int, default=224)
    ap.add_argument("--epochs", type=int, default=40)
    ap.add_argument("--batch", type=int, default=32)
    ap.add_argument("--lr", type=float, default=3e-4)
    ap.add_argument("--weight-decay", type=float, default=0.05)
    ap.add_argument("--out", type=Path, required=True)
    args = ap.parse_args()

    device = "cuda" if torch.cuda.is_available() else "cpu"
    print(f"device: {device}")
    args.out.mkdir(parents=True, exist_ok=True)

    train_ds = ImageFolder(args.data / "train", transform=build_train_transform(args.img_size))
    val_ds = ImageFolder(args.data / "val", transform=build_eval_transform(args.img_size))
    class_names = train_ds.classes
    n = len(class_names)
    print(f"{n} classes: {class_names}")

    # Class-weighted loss: field datasets (PlantDoc) are imbalanced.
    counts = np.bincount([y for _, y in train_ds.samples], minlength=n).astype(np.float32)
    weights = torch.tensor((counts.sum() / (n * np.maximum(counts, 1))), dtype=torch.float32)
    criterion = nn.CrossEntropyLoss(weight=weights.to(device), label_smoothing=0.1)

    train_ld = DataLoader(train_ds, batch_size=args.batch, shuffle=True, num_workers=4, pin_memory=True)
    val_ld = DataLoader(val_ds, batch_size=args.batch, shuffle=False, num_workers=4, pin_memory=True)

    model = timm.create_model(args.backbone, pretrained=args.pretrained_ckpt is None, num_classes=n)
    if args.pretrained_ckpt:
        load_pretrained_backbone(model, args.pretrained_ckpt)
    model.to(device)

    optimizer = torch.optim.AdamW(model.parameters(), lr=args.lr, weight_decay=args.weight_decay)
    scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(optimizer, T_max=args.epochs)

    best_f1 = -1.0
    for epoch in range(1, args.epochs + 1):
        tr_loss, tr_acc, tr_f1 = run_epoch(model, train_ld, device, criterion, optimizer)
        va_loss, va_acc, va_f1 = run_epoch(model, val_ld, device, criterion)
        scheduler.step()
        print(f"epoch {epoch:3d} | train f1 {tr_f1:.3f} acc {tr_acc:.3f} "
              f"| val f1 {va_f1:.3f} acc {va_acc:.3f} loss {va_loss:.3f}")
        if va_f1 > best_f1:
            best_f1 = va_f1
            torch.save(
                {"model_state": model.state_dict(), "class_names": class_names,
                 "backbone": args.backbone, "img_size": args.img_size},
                args.out / "best.pt",
            )
            (args.out / "labels.json").write_text(json.dumps(class_names, indent=2))
            print(f"  saved best (val macro-F1 {best_f1:.3f})")

    print(f"\nbest val macro-F1: {best_f1:.3f} -> {args.out / 'best.pt'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
