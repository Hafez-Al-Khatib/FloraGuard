"""Per-plant object detector: ONNX YOLO → a list of diagnosed, boxed plants.

Boxes each plant/leaf and gives each its own coarse group (reliable) and, with
the node's crop, a specific disease — reusing services.GROUP_OF/CROP_OF so the
whole stack agrees. Pure-numpy decode + NMS (no torch in the edge). Safe fallback
to an empty list when the model is absent, exactly like InferenceEngine.
"""
from __future__ import annotations

import io
import logging

import numpy as np
from PIL import Image

from config import Settings
from services import CROP_OF, GROUP_OF

_log = logging.getLogger(__name__)


def letterbox(img: Image.Image, size: int) -> tuple[np.ndarray, float, float, float]:
    """Resize keeping aspect into a size×size gray canvas. Returns
    (CHW float32 0-1 batch-less array, scale, pad_x, pad_y)."""
    w0, h0 = img.size
    scale = min(size / w0, size / h0)
    nw, nh = round(w0 * scale), round(h0 * scale)
    resized = img.resize((nw, nh), Image.BILINEAR)
    canvas = Image.new("RGB", (size, size), (114, 114, 114))
    pad_x, pad_y = (size - nw) // 2, (size - nh) // 2
    canvas.paste(resized, (pad_x, pad_y))
    arr = np.asarray(canvas, np.float32).transpose(2, 0, 1) / 255.0
    return arr, scale, float(pad_x), float(pad_y)


def nms(boxes: np.ndarray, scores: np.ndarray, iou_thres: float) -> list[int]:
    """Greedy NMS on xyxy boxes. Returns kept indices, highest score first."""
    if len(boxes) == 0:
        return []
    x1, y1, x2, y2 = boxes[:, 0], boxes[:, 1], boxes[:, 2], boxes[:, 3]
    areas = np.maximum(0.0, x2 - x1) * np.maximum(0.0, y2 - y1)
    order = scores.argsort()[::-1]
    keep: list[int] = []
    while order.size > 0:
        i = int(order[0])
        keep.append(i)
        if order.size == 1:
            break
        xx1 = np.maximum(x1[i], x1[order[1:]])
        yy1 = np.maximum(y1[i], y1[order[1:]])
        xx2 = np.minimum(x2[i], x2[order[1:]])
        yy2 = np.minimum(y2[i], y2[order[1:]])
        inter = np.maximum(0.0, xx2 - xx1) * np.maximum(0.0, yy2 - yy1)
        iou = inter / np.maximum(areas[i] + areas[order[1:]] - inter, 1e-9)
        order = order[1:][iou <= iou_thres]
    return keep


class Detector:
    """ONNX YOLOv8/v11 detector with grouped, crop-aware per-box diagnosis."""

    def __init__(self, settings: Settings):
        self.conf = settings.detector_conf
        self.iou = settings.detector_iou
        self.labels: list[str] = []
        self.session = None
        self.imgsz = 640
        if not settings.detector_path.exists():
            _log.info("No detector at %s — per-plant detection disabled (classifier fallback).",
                      settings.detector_path)
            return
        try:
            import json

            import onnxruntime as ort

            labels_path = settings.detector_path.with_name("detector_labels.json")
            self.labels = json.loads(labels_path.read_text()) if labels_path.exists() else []
            providers = [p for p in ("CUDAExecutionProvider", "CPUExecutionProvider")
                         if p in ort.get_available_providers()] or ["CPUExecutionProvider"]
            self.session = ort.InferenceSession(str(settings.detector_path), providers=providers)
            shape = self.session.get_inputs()[0].shape
            if len(shape) == 4 and isinstance(shape[3], int):
                self.imgsz = shape[3]
            # Precompute the crop-restricted class-index sets.
            self._crop_indices = {
                c: [i for i, lbl in enumerate(self.labels) if CROP_OF.get(lbl) == c]
                for c in ("tomato", "potato", "pepper")
            }
            _log.info("detector_ready classes=%d imgsz=%d", len(self.labels), self.imgsz)
        except Exception as exc:  # pragma: no cover
            _log.warning("Failed to load detector: %s", exc)
            self.session = None

    def detect(self, image_bytes: bytes, crop: str | None = None) -> list[dict]:
        """Return a list of boxes: {box:[cx,cy,w,h] normalized, group, fine,
        confidence, crop}. Empty when the model is absent or nothing is found."""
        if self.session is None:
            return []
        img = Image.open(io.BytesIO(image_bytes)).convert("RGB")
        w0, h0 = img.size
        arr, scale, pad_x, pad_y = letterbox(img, self.imgsz)
        out = self.session.run(None, {self.session.get_inputs()[0].name: arr[None]})[0]
        preds = out[0]  # (4+nc, N) or (N, 4+nc)
        nc = len(self.labels)
        if preds.shape[0] == 4 + nc:
            preds = preds.T  # → (N, 4+nc)
        boxes_cxcywh = preds[:, :4]
        scores_all = preds[:, 4:4 + nc]
        # Optional crop constraint: only consider this crop's class columns.
        cols = self._crop_indices.get(crop) if crop else None
        if cols:
            cls_local = np.argmax(scores_all[:, cols], axis=1)
            cls = np.array([cols[i] for i in cls_local])
            conf = scores_all[np.arange(len(preds)), cls]
        else:
            cls = np.argmax(scores_all, axis=1)
            conf = scores_all[np.arange(len(preds)), cls]
        keep = conf >= self.conf
        if not keep.any():
            return []
        boxes_cxcywh, cls, conf = boxes_cxcywh[keep], cls[keep], conf[keep]
        # cxcywh (letterboxed px) → xyxy → un-letterbox → original px.
        cx, cy, bw, bh = boxes_cxcywh.T
        x1 = (cx - bw / 2 - pad_x) / scale
        y1 = (cy - bh / 2 - pad_y) / scale
        x2 = (cx + bw / 2 - pad_x) / scale
        y2 = (cy + bh / 2 - pad_y) / scale
        xyxy = np.stack([x1, y1, x2, y2], axis=1)
        # Class-wise NMS.
        results: list[dict] = []
        for c in np.unique(cls):
            m = cls == c
            idx = nms(xyxy[m], conf[m], self.iou)
            cb, cs = xyxy[m][idx], conf[m][idx]
            fine = self.labels[int(c)]
            for (bx1, by1, bx2, by2), sc in zip(cb, cs):
                bx1, bx2 = np.clip([bx1, bx2], 0, w0)
                by1, by2 = np.clip([by1, by2], 0, h0)
                if bx2 <= bx1 or by2 <= by1:
                    continue
                results.append({
                    "box": [float((bx1 + bx2) / 2 / w0), float((by1 + by2) / 2 / h0),
                            float((bx2 - bx1) / w0), float((by2 - by1) / h0)],
                    "group": GROUP_OF.get(fine, "healthy"),
                    "fine": fine,
                    "confidence": float(sc),
                    "crop": CROP_OF.get(fine),
                })
        results.sort(key=lambda r: -r["confidence"])
        return results
