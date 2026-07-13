"""Unit tests for the per-plant Detector (math always; model test skips if absent)."""
import io
from pathlib import Path

import numpy as np
import pytest
from PIL import Image

from config import Settings
from detector import Detector, letterbox, nms
from services import COARSE_GROUPS


def _fake_jpeg(size=(320, 240)) -> bytes:
    arr = np.random.randint(0, 255, (size[1], size[0], 3), dtype=np.uint8)
    buf = io.BytesIO()
    Image.fromarray(arr).save(buf, format="JPEG")
    return buf.getvalue()


def test_letterbox_scale_and_pad():
    arr, scale, px, py = letterbox(Image.new("RGB", (320, 160)), 640)
    assert arr.shape == (3, 640, 640)
    assert abs(scale - 2.0) < 1e-6           # min(640/320, 640/160)
    assert px == 0 and py == 160             # 320*2=640 wide, 160*2=320 tall → pad top/bottom


def test_nms_suppresses_overlap_keeps_distinct():
    boxes = np.array([[0, 0, 10, 10], [1, 1, 11, 11], [100, 100, 110, 110]], float)
    scores = np.array([0.9, 0.8, 0.7])
    keep = nms(boxes, scores, 0.45)
    assert 0 in keep and 2 in keep and 1 not in keep


def test_detector_absent_returns_empty():
    det = Detector(Settings(detector_path=Path("models/__does_not_exist__.onnx")))
    assert det.session is None
    assert det.detect(_fake_jpeg()) == []


def test_detector_returns_normalized_grouped_boxes():
    det = Detector(Settings())
    if det.session is None:
        pytest.skip("detector model not present in this environment")
    for b in det.detect(_fake_jpeg()):
        assert len(b["box"]) == 4 and all(0.0 <= v <= 1.0 for v in b["box"])
        assert b["group"] in COARSE_GROUPS
        assert 0.0 <= b["confidence"] <= 1.0
