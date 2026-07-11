"""Unit tests for the ONNX inference engine and treatment database."""
import io

import numpy as np
import pytest
from PIL import Image

from config import Settings
from services import InferenceEngine, TreatmentDB


def _make_jpeg(size: tuple[int, int] = (128, 128)) -> bytes:
    arr = np.random.randint(0, 255, (size[1], size[0], 3), dtype=np.uint8)
    buf = io.BytesIO()
    Image.fromarray(arr).save(buf, format="JPEG")
    return buf.getvalue()


# ---------- InferenceEngine ----------

def test_preprocess_produces_nchw_float_tensor():
    engine = InferenceEngine(Settings())
    # input_size is model-driven (W, H); the tensor is NCHW.
    w, h = engine.input_size
    tensor = engine._preprocess(_make_jpeg())
    assert tensor.shape == (1, 3, h, w)
    assert tensor.dtype == np.float32


def test_preprocess_resizes_non_square_input():
    engine = InferenceEngine(Settings())
    w, h = engine.input_size
    tensor = engine._preprocess(_make_jpeg(size=(640, 480)))
    assert tensor.shape == (1, 3, h, w)


def test_inference_fallback_when_model_missing(tmp_path):
    settings = Settings(model_path=tmp_path / "does-not-exist.onnx")
    engine = InferenceEngine(settings)
    assert engine.session is None
    assert engine.predict(_make_jpeg()) == ("model_unavailable", 0.0)


def test_inference_real_model_returns_valid_label():
    settings = Settings()
    engine = InferenceEngine(settings)
    if engine.session is None:
        pytest.skip("ONNX model file not available in this environment")
    label, confidence = engine.predict(_make_jpeg())
    assert label in settings.class_labels
    assert 0.0 <= confidence <= 1.0


# ---------- TreatmentDB ----------

def test_treatment_lookup_known_disease():
    options = TreatmentDB.get("Tomato_Late_blight")
    assert options is not None
    assert any(opt["type"] == "chemical" for opt in options)
    assert all(opt["actions"] for opt in options)


def test_treatment_unknown_label_returns_none():
    assert TreatmentDB.get("Nonexistent_Class") is None


def test_healthy_labels_exclude_diseases():
    healthy = TreatmentDB.healthy_labels()
    assert "Tomato_healthy" in healthy
    assert "Pepper__bell___healthy" in healthy
    assert "Tomato_Late_blight" not in healthy


def test_every_model_label_has_a_treatment_entry():
    """Guard against model/treatment drift: each class the model can emit must
    have guidance, otherwise /analyze would surface a disease with no advice."""
    settings = Settings()
    missing = [label for label in settings.class_labels if TreatmentDB.get(label) is None]
    assert not missing, f"Labels missing treatment mappings: {missing}"
