import os
import sys

sys.path.insert(0, os.path.dirname(__file__))

from labels import DET_CLASSES, det_crop, det_group, plantdoc_to_det  # noqa: E402


def test_det_maps_align_with_groups():
    assert DET_CLASSES, "detector must have classes"
    for c in DET_CLASSES:
        assert det_group(c) in {"healthy", "blight", "leaf_spot", "viral", "pest"}
        assert det_crop(c) in {"tomato", "potato", "pepper", None}


def test_plantdoc_names_map_to_det_classes():
    assert plantdoc_to_det("Tomato leaf late blight") == "Tomato_Late_blight"
    assert det_group("Tomato_Late_blight") == "blight"
    assert det_crop("Tomato_Late_blight") == "tomato"
    # A PlantDoc class outside our crops is dropped.
    assert plantdoc_to_det("Apple Scab Leaf") is None


def test_every_det_class_has_group_and_crop():
    for c in DET_CLASSES:
        assert isinstance(det_group(c), str)
        assert det_crop(c) is not None  # all our classes are crop diseases/healthy
