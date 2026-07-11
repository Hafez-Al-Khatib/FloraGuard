"""Augmentation that closes the lab -> field / ESP32-CAM gap.

PlantVillage-trained models fail in the field because training images are single
centred leaves on uniform backgrounds, captured with good optics. Real captures
from an ESP32-CAM (OV2640) are low-resolution, JPEG-compressed, often
back-lit or white-balance-skewed, and full of background clutter. We can't
change the source images, but we CAN degrade them at train time to match the
deployment distribution — this is the single highest-leverage part of the whole
pipeline.

`build_train_transform` returns a torchvision transform that, on top of the
usual geometric/colour jitter, applies two custom degradations that mimic the
camera: random JPEG re-compression and random downscale-then-upscale.
"""
from __future__ import annotations

import io
import random

from PIL import Image
from torchvision import transforms

IMAGENET_MEAN = (0.485, 0.456, 0.406)
IMAGENET_STD = (0.229, 0.224, 0.225)


class RandomJPEG:
    """Re-encode the PIL image as JPEG at a random low quality.

    The ESP32-CAM emits heavily compressed JPEGs; training on pristine images
    leaves the model brittle to compression artefacts it will always see in
    production.
    """

    def __init__(self, qmin: int = 20, qmax: int = 75, p: float = 0.7):
        self.qmin, self.qmax, self.p = qmin, qmax, p

    def __call__(self, img: Image.Image) -> Image.Image:
        if random.random() > self.p:
            return img
        q = random.randint(self.qmin, self.qmax)
        buf = io.BytesIO()
        img.convert("RGB").save(buf, format="JPEG", quality=q)
        buf.seek(0)
        return Image.open(buf).convert("RGB")


class RandomDownscale:
    """Downsample to a random low resolution then upsample back.

    Simulates the OV2640's limited effective resolution and the server-side
    resize chain. Destroys fine detail the lab images have but the cam never
    delivers.
    """

    def __init__(self, min_frac: float = 0.35, max_frac: float = 0.9, p: float = 0.6):
        self.min_frac, self.max_frac, self.p = min_frac, max_frac, p

    def __call__(self, img: Image.Image) -> Image.Image:
        if random.random() > self.p:
            return img
        w, h = img.size
        frac = random.uniform(self.min_frac, self.max_frac)
        small = img.resize((max(1, int(w * frac)), max(1, int(h * frac))), Image.BILINEAR)
        return small.resize((w, h), Image.BILINEAR)


def build_train_transform(img_size: int = 224) -> transforms.Compose:
    """Aggressive, cam-matched training augmentation."""
    return transforms.Compose(
        [
            # Framing variance: field captures are rarely a centred leaf.
            transforms.RandomResizedCrop(img_size, scale=(0.5, 1.0), ratio=(0.75, 1.33)),
            transforms.RandomHorizontalFlip(),
            transforms.RandomVerticalFlip(p=0.2),
            transforms.RandomRotation(20),
            # Lighting / white-balance variance.
            transforms.ColorJitter(brightness=0.3, contrast=0.3, saturation=0.3, hue=0.05),
            transforms.RandomApply([transforms.GaussianBlur(3, sigma=(0.1, 1.5))], p=0.3),
            # Camera signature: compression + resolution loss.
            RandomDownscale(),
            RandomJPEG(),
            transforms.ToTensor(),
            transforms.Normalize(IMAGENET_MEAN, IMAGENET_STD),
            # Occlusion / background robustness.
            transforms.RandomErasing(p=0.25, scale=(0.02, 0.15)),
        ]
    )


def build_eval_transform(img_size: int = 224) -> transforms.Compose:
    """Deterministic eval transform. Mirror this EXACTLY in the edge server's
    `_preprocess` (resize to img_size, ToTensor scales to 0-1, ImageNet norm)."""
    return transforms.Compose(
        [
            transforms.Resize((img_size, img_size)),
            transforms.ToTensor(),
            transforms.Normalize(IMAGENET_MEAN, IMAGENET_STD),
        ]
    )
