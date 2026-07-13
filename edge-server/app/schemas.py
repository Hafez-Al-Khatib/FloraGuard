"""Pydantic request/response models."""
import re
from datetime import datetime
from typing import Annotated

from pydantic import BaseModel, Field, StringConstraints, field_validator

# THE node-id rule. schemas models, path validation, and the MQTT ingest
# (services._NODE_ID_RE) all share this single pattern — tightening it in one
# place must tighten every entry point at once.
NODE_ID_PATTERN = re.compile(r"^[a-zA-Z0-9_-]{1,64}$")

NodeId = Annotated[str, StringConstraints(pattern=r"^[a-zA-Z0-9_-]{1,64}$")]


class NodeIdPath(BaseModel):
    node_id: NodeId


class DiagnosticResult(BaseModel):
    issue: str
    confidence: float = Field(..., ge=0.0, le=1.0)


class CameraUploadResponse(BaseModel):
    status: str
    buffered: bool
    size_bytes: int


class TreatmentOption(BaseModel):
    type: str = Field(..., description="Treatment category: cultural, chemical, biological, or none")
    actions: list[str] = Field(..., description="List of actionable steps")


class SpecificDiagnosis(BaseModel):
    """Most-likely exact disease within the coarse group, surfaced only when the
    model clears the specific-confidence bar. Carries the per-disease treatment
    from the fine-grained TreatmentDB."""
    label: str
    confidence: float = Field(..., ge=0.0, le=1.0)
    treatments: list[TreatmentOption] | None = None


class DetectionBox(BaseModel):
    """One detected plant/leaf. `box` is normalized [cx, cy, w, h] (0-1), or None
    for a whole-frame (classifier-fallback) diagnosis."""
    box: list[float] | None = None
    group: str
    fine: str = ""
    confidence: float = Field(..., ge=0.0, le=1.0)


class CameraAnalysisResponse(BaseModel):
    node_id: str
    anomalies: DiagnosticResult | None
    inference_ms: float
    treatments: list[TreatmentOption] | None = None
    # The specific disease + its treatment, when confidence warrants it.
    specific: SpecificDiagnosis | None = None
    # Per-plant boxes (empty for the whole-frame classifier fallback).
    detections: list[DetectionBox] = []


class ChatQuery(BaseModel):
    node_id: NodeId
    user_query: str = Field(..., min_length=1, max_length=2048)

    @field_validator("user_query")
    @classmethod
    def _sanitize_query(cls, value: str) -> str:
        # Strip control characters that break prompts or logs
        return "".join(ch for ch in value if ord(ch) >= 32 or ch in {"\n", "\t"})


class TelemetryPayload(BaseModel):
    node_id: NodeId
    moisture: float | None = Field(None, ge=0.0, le=100.0)
    temperature: float | None = Field(None, ge=-50.0, le=80.0)
    ec: float | None = Field(None, ge=0.0)
    battery_pct: float | None = Field(None, ge=0.0, le=100.0)
    timestamp: datetime | None = None
