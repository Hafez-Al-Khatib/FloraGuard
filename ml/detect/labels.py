"""Detection class space + group/crop maps, aligned with the edge server.

The detector's classes are the tomato/potato/pepper fine diseases (the crops we
grow). Each box collapses to a coarse group (reliable) and a crop, mirroring
`edge-server/app/services.py` COARSE_GROUPS/CROP_OF so the whole stack agrees.
Kept self-contained (no cross-package import) so it runs in a plain ml/ venv.
"""
from __future__ import annotations

import re

# Mirror of services.COARSE_GROUPS (fine PlantVillage labels per group).
COARSE_GROUPS: dict[str, tuple[str, ...]] = {
    "healthy": ("Pepper__bell___healthy", "Potato___healthy", "Tomato_healthy"),
    "blight": (
        "Potato___Early_blight", "Potato___Late_blight",
        "Tomato_Early_blight", "Tomato_Late_blight",
    ),
    "leaf_spot": (
        "Pepper__bell___Bacterial_spot", "Tomato_Bacterial_spot",
        "Tomato_Septoria_leaf_spot", "Tomato__Target_Spot", "Tomato_Leaf_Mold",
    ),
    "viral": (
        "Tomato__Tomato_YellowLeaf__Curl_Virus", "Tomato__Tomato_mosaic_virus",
    ),
    "pest": ("Tomato_Spider_mites_Two_spotted_spider_mite",),
}
_GROUP_OF: dict[str, str] = {f: g for g, fs in COARSE_GROUPS.items() for f in fs}


def _crop_of(label: str) -> str | None:
    low = label.lower()
    for crop in ("pepper", "potato", "tomato"):
        if crop in low:
            return crop
    return None


# The detector predicts these fine classes (a stable, sorted list → class index).
DET_CLASSES: list[str] = sorted(_GROUP_OF)


def det_group(cls: str) -> str:
    """Coarse group for a detection class."""
    return _GROUP_OF.get(cls, "healthy")


def det_crop(cls: str) -> str | None:
    """Crop (tomato|potato|pepper) for a detection class, or None."""
    return _crop_of(cls)


def canon(name: str) -> str:
    """Canonical form for matching free-text PlantDoc box names to DET_CLASSES."""
    return re.sub(r"[^a-z0-9]+", "_", name.lower()).strip("_")


# PlantDoc detection object names (free text) → our DET_CLASSES. Canonicalised on
# both sides, mirroring ml/plantdoc_to_pv.py's classification mapping.
PLANTDOC_TO_DET: dict[str, str] = {
    canon("Bell_pepper leaf"): "Pepper__bell___healthy",
    canon("Bell_pepper leaf spot"): "Pepper__bell___Bacterial_spot",
    canon("Potato leaf early blight"): "Potato___Early_blight",
    canon("Potato leaf late blight"): "Potato___Late_blight",
    canon("Tomato leaf bacterial spot"): "Tomato_Bacterial_spot",
    canon("Tomato Early blight leaf"): "Tomato_Early_blight",
    canon("Tomato leaf late blight"): "Tomato_Late_blight",
    canon("Tomato mold leaf"): "Tomato_Leaf_Mold",
    canon("Tomato Septoria leaf spot"): "Tomato_Septoria_leaf_spot",
    canon("Tomato two spotted spider mites leaf"): "Tomato_Spider_mites_Two_spotted_spider_mite",
    canon("Tomato leaf yellow virus"): "Tomato__Tomato_YellowLeaf__Curl_Virus",
    canon("Tomato leaf mosaic virus"): "Tomato__Tomato_mosaic_virus",
    canon("Tomato leaf"): "Tomato_healthy",
}


def plantdoc_to_det(box_name: str) -> str | None:
    """Map a PlantDoc VOC object name to a DET_CLASSES label, or None to drop."""
    return PLANTDOC_TO_DET.get(canon(box_name))
