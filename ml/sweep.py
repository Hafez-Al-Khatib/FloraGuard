"""Hyperparameter search for the field model (Optuna).

Model quality — not quantization — is the accuracy ceiling here. This searches
the knobs that matter most for a small-data field classifier and reports the
best config to plug straight into ml/train.py for a full run:

  backbone         mobilenetv3 / efficientnet / efficientnetv2 / convnext / resnet34
  img_size         192 / 224 / 256   (bigger often helps, costs compute)
  lr, weight_decay optimizer strength
  label_smoothing  regularization
  drop_rate        classifier dropout (small data overfits fast)

Objective = validation macro-F1 (balanced across classes, matching how we judge
the model). Bad trials are pruned early. GPU (Colab) strongly recommended.

    pip install optuna
    python ml/sweep.py --data datasets/pv15 --trials 30 --epochs 20 --out ml/runs/sweep

Tip: sweep on the COARSE dataset (ml/coarsen.py build) to tune directly for the
5-group metric you deploy — pass --data datasets/coarse5.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np
import optuna
import timm
import torch
import torch.nn as nn
from torch.utils.data import DataLoader
from torchvision.datasets import ImageFolder

from augment import build_eval_transform, build_train_transform
from train import load_pretrained_backbone, run_epoch

BACKBONES = [
    "mobilenetv3_large_100",       # current
    "mobilenetv4_conv_medium",     # 2024 successor to V3; better acc/latency, quantizes well
    "mobilenetv4_conv_large",      # more capacity, still fine server-side on a Pi 5
    "efficientnet_b0",
    "tf_efficientnetv2_b0",
    "convnext_tiny",
    "resnet50",                    # the "standard ResNet" reference point
]


def _class_weights(dataset, n: int, device: str) -> torch.Tensor:
    counts = np.bincount([y for _, y in dataset.samples], minlength=n).astype(np.float32)
    return torch.tensor(counts.sum() / (n * np.maximum(counts, 1)), dtype=torch.float32).to(device)


def objective(trial: optuna.Trial, args, device: str) -> float:
    backbone = trial.suggest_categorical("backbone", BACKBONES)
    img_size = trial.suggest_categorical("img_size", [192, 224, 256])
    lr = trial.suggest_float("lr", 1e-4, 3e-3, log=True)
    weight_decay = trial.suggest_float("weight_decay", 1e-4, 1e-1, log=True)
    label_smoothing = trial.suggest_float("label_smoothing", 0.0, 0.15)
    drop_rate = trial.suggest_float("drop_rate", 0.0, 0.4)

    train_ds = ImageFolder(args.data / "train", transform=build_train_transform(img_size))
    val_ds = ImageFolder(args.data / "val", transform=build_eval_transform(img_size))
    n = len(train_ds.classes)
    train_ld = DataLoader(train_ds, batch_size=args.batch, shuffle=True,
                          num_workers=args.workers, pin_memory=True)
    val_ld = DataLoader(val_ds, batch_size=args.batch, shuffle=False,
                        num_workers=args.workers, pin_memory=True)

    criterion = nn.CrossEntropyLoss(weight=_class_weights(train_ds, n, device),
                                    label_smoothing=label_smoothing)
    model = timm.create_model(backbone, pretrained=args.pretrained_ckpt is None,
                              num_classes=n, drop_rate=drop_rate)
    if args.pretrained_ckpt:
        load_pretrained_backbone(model, args.pretrained_ckpt)
    model.to(device)
    optimizer = torch.optim.AdamW(model.parameters(), lr=lr, weight_decay=weight_decay)
    scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(optimizer, T_max=args.epochs)

    best = 0.0
    for epoch in range(1, args.epochs + 1):
        run_epoch(model, train_ld, device, criterion, optimizer)
        _, _, val_f1 = run_epoch(model, val_ld, device, criterion)
        scheduler.step()
        best = max(best, val_f1)
        trial.report(val_f1, epoch)
        if trial.should_prune():
            raise optuna.TrialPruned()
    return best


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", type=Path, required=True, help="ImageFolder root (train/ val/)")
    ap.add_argument("--trials", type=int, default=30)
    ap.add_argument("--epochs", type=int, default=20, help="epochs per trial (short; final run is longer)")
    ap.add_argument("--batch", type=int, default=64)
    ap.add_argument("--workers", type=int, default=2)
    ap.add_argument("--pretrained-ckpt", type=Path, default=None)
    ap.add_argument("--out", type=Path, default=Path("ml/runs/sweep"))
    args = ap.parse_args()

    device = "cuda" if torch.cuda.is_available() else "cpu"
    print(f"device: {device}   trials: {args.trials}   epochs/trial: {args.epochs}")
    args.out.mkdir(parents=True, exist_ok=True)

    study = optuna.create_study(
        direction="maximize",
        pruner=optuna.pruners.MedianPruner(n_warmup_steps=5),
    )
    study.optimize(lambda t: objective(t, args, device), n_trials=args.trials)

    print(f"\nbest val macro-F1: {study.best_value:.3f}")
    print("best config:\n" + json.dumps(study.best_params, indent=2))
    (args.out / "best_config.json").write_text(
        json.dumps({"value": study.best_value, "params": study.best_params}, indent=2)
    )
    p = study.best_params
    print("\nFull training with the winning config:")
    print(
        f"  python ml/train.py --data {args.data} --backbone {p['backbone']} "
        f"--img-size {p['img_size']} --lr {p['lr']:.5f} "
        f"--weight-decay {p['weight_decay']:.5f} "
        f"--label-smoothing {p['label_smoothing']:.3f} --drop-rate {p['drop_rate']:.3f} "
        f"--epochs 200 --out ml/runs/best"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
