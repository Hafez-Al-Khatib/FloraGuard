"""FastAPI route handlers."""
from __future__ import annotations

import asyncio
import json
import structlog
import time
from typing import Annotated

from fastapi import APIRouter, Depends, Header, HTTPException, Request, Response, status
from fastapi.responses import StreamingResponse
from slowapi import Limiter
from slowapi.util import get_remote_address

from auth import Principal, require_admin, require_auth
from config import get_settings
from schemas import (
    CameraAnalysisResponse,
    CameraUploadResponse,
    ChatQuery,
    DiagnosticResult,
    NodeIdPath,
    TelemetryPayload,
)
from services import (
    AgronomistChat,
    Cache,
    ControlEngine,
    InferenceEngine,
    MqttPublisher,
    TimeSeriesDB,
    TreatmentDB,
)

logger = structlog.get_logger()
router = APIRouter(prefix="/api/v1")
limiter = Limiter(key_func=get_remote_address)

# ---------- dependencies ----------
# Services are created once in the app lifespan (see main.py) and stored on
# app.state. These providers return those singletons. The lazy fallback keeps
# unit tests that exercise routes without triggering the lifespan working, and
# lets tests swap implementations via app.dependency_overrides.

def get_cache(request: Request) -> Cache:
    if getattr(request.app.state, "cache", None) is None:
        request.app.state.cache = Cache(get_settings())
    return request.app.state.cache


def get_tsdb(request: Request) -> TimeSeriesDB:
    if getattr(request.app.state, "tsdb", None) is None:
        request.app.state.tsdb = TimeSeriesDB(get_settings())
    return request.app.state.tsdb


def get_inference(request: Request) -> InferenceEngine:
    if getattr(request.app.state, "inference", None) is None:
        request.app.state.inference = InferenceEngine(get_settings())
    return request.app.state.inference


def get_chat(request: Request) -> AgronomistChat:
    if getattr(request.app.state, "chat", None) is None:
        request.app.state.chat = AgronomistChat(get_settings())
    return request.app.state.chat


def get_control_engine(request: Request) -> ControlEngine:
    engine = getattr(request.app.state, "control_engine", None)
    if engine is None:
        # Lazy fallback (tests / no lifespan). No publisher -> virtual actuator.
        engine = ControlEngine(get_settings(), get_cache(request), None)
        request.app.state.control_engine = engine
    return engine


# ---------- health ----------

@router.get("/health")
async def health() -> dict:
    return {"status": "ok", "service": "pms-api"}


# ---------- camera ----------

@router.post(
    "/node/{node_id}/upload-frame",
    response_model=CameraUploadResponse,
)
async def receive_camera_frame(
    node_id: str,
    request: Request,
    content_type: Annotated[str | None, Header()] = None,
    content_length: Annotated[str | None, Header()] = None,
    cache: Cache = Depends(get_cache),
    principal: Principal = Depends(require_auth),
) -> CameraUploadResponse:
    principal.assert_node(node_id)
    """Accept a raw JPEG/PNG/WebP binary body from an ESP32 camera node.

    The ESP32 sends the frame bytes directly with Content-Type: image/jpeg —
    no multipart wrapper. Content-Length is required so the size guard fires
    before the body is read into memory.
    """
    settings = get_settings()
    NodeIdPath(node_id=node_id)

    if content_length is None:
        raise HTTPException(
            status_code=status.HTTP_411_LENGTH_REQUIRED,
            detail="Content-Length header is required.",
        )
    try:
        cl_int = int(content_length)
    except ValueError:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Content-Length must be an integer.",
        )
    if cl_int > settings.max_image_size:
        raise HTTPException(
            status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
            detail=f"Image exceeds maximum size of {settings.max_image_size} bytes.",
        )

    if content_type not in settings.allowed_image_types:
        raise HTTPException(
            status_code=status.HTTP_415_UNSUPPORTED_MEDIA_TYPE,
            detail=f"Content-Type {content_type!r} not allowed. "
                   f"Accepted: {sorted(settings.allowed_image_types)}",
        )

    data = await request.body()
    if len(data) > settings.max_image_size:
        raise HTTPException(
            status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
            detail=f"Actual body size {len(data)} exceeds limit.",
        )
    if not _is_valid_image(data):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Body does not match a valid JPEG/PNG/WebP image.",
        )

    await cache.set_camera_frame(node_id, data)

    # Auto-analyze: a camera node is a dumb capture device, so the edge runs
    # inference on every uploaded frame and records the detection. The ESP32-CAM
    # just uploads and sleeps; the in-app capture benefits too (no separate
    # /analyze call needed). Best-effort — an inference failure never fails the
    # upload, so the frame is still buffered for a manual /analyze.
    try:
        inference = get_inference(request)
        label, confidence = inference.predict(data)
        await _record_detection(cache, node_id, label, confidence)
        await logger.ainfo(
            "camera_frame_analyzed", node_id=node_id, issue=label, confidence=confidence
        )
    except Exception as exc:
        await logger.aerror("auto_analyze_failed", node_id=node_id, error=str(exc))

    await logger.ainfo("camera_frame_received", node_id=node_id, size=len(data))
    return CameraUploadResponse(status="success", buffered=True, size_bytes=len(data))


def _is_valid_image(data: bytes) -> bool:
    return (
        data.startswith(b"\xff\xd8\xff")  # JPEG
        or data.startswith(b"\x89PNG\r\n\x1a\n")  # PNG
        or data.startswith(b"RIFF") and data[8:12] == b"WEBP"  # WebP
    )


async def _record_detection(
    cache: Cache, node_id: str, label: str, confidence: float
) -> str:
    """Persist a disease detection and surface it: cache the diagnosis, pair the
    camera node, push it to the live SSE feed, and log a safety suggestion for a
    high-confidence disease. Returns the detection timestamp.

    Shared by GET /analyze (operator-triggered) and the auto-analyze on
    POST /upload-frame (autonomous ESP32-CAM / in-app capture).
    """
    detected_at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    await cache.set_camera_diagnostics(
        node_id, {"issue": label, "confidence": confidence, "timestamp": detected_at}
    )
    await cache.register_node(node_id, profile={"kind": "camera"})
    await cache.publish_telemetry_stream({
        "node_id": node_id,
        "data": json.dumps({
            "detection": {"issue": label, "confidence": confidence, "at": detected_at}
        }),
    })
    # Safety-first automation: log a suggestion, never actuate without confirmation.
    if label not in TreatmentDB.healthy_labels() and confidence > 0.75:
        await cache.log_automation_decision(
            node_id=node_id,
            decision="SUGGESTION",
            context={
                "issue": label,
                "confidence": confidence,
                "message": "High-confidence anomaly detected. Awaiting operator confirmation.",
            },
        )
    return detected_at


@router.get(
    "/node/{node_id}/analyze",
    response_model=CameraAnalysisResponse,
    dependencies=[Depends(require_auth)],
)
async def evaluate_crop_health(
    node_id: str,
    cache: Cache = Depends(get_cache),
    inference: InferenceEngine = Depends(get_inference),
) -> CameraAnalysisResponse:
    NodeIdPath(node_id=node_id)

    img_bytes = await cache.get_camera_frame(node_id)
    if not img_bytes:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="No fresh image found in memory bank.",
        )

    t0 = time.perf_counter()
    try:
        label, confidence = inference.predict(img_bytes)
    except Exception as exc:
        await logger.aerror("inference_failed", node_id=node_id, error=str(exc))
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Inference engine failed to process frame.",
        ) from exc
    inference_ms = round((time.perf_counter() - t0) * 1000, 2)

    diagnostic = DiagnosticResult(issue=label, confidence=confidence)
    # Cache, pair, push to SSE, and log a safety suggestion (shared with the
    # auto-analyze on /upload-frame).
    await _record_detection(cache, node_id, label, confidence)

    # Attach treatment recommendations when a known disease is detected.
    treatments = None
    if label in TreatmentDB._MAPPING and label not in TreatmentDB.healthy_labels():
        treatments = [
            {"type": t["type"], "actions": t["actions"]}
            for t in TreatmentDB.get(label) or []
        ]

    return CameraAnalysisResponse(
        node_id=node_id,
        anomalies=diagnostic,
        inference_ms=inference_ms,
        treatments=treatments,
    )


@router.get(
    "/node/{node_id}/frame",
    dependencies=[Depends(require_auth)],
)
async def get_camera_frame(
    node_id: str,
    cache: Cache = Depends(get_cache),
) -> Response:
    """Return the latest cached camera frame as a JPEG, for the dashboard to
    show the actual leaf alongside the detection."""
    NodeIdPath(node_id=node_id)
    data = await cache.get_camera_frame(node_id)
    if not data:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="No camera frame cached for this node.",
        )
    return Response(content=data, media_type="image/jpeg")


@router.get(
    "/node/{node_id}/diagnostics",
    dependencies=[Depends(require_auth)],
)
async def latest_diagnostics(
    node_id: str,
    cache: Cache = Depends(get_cache),
) -> dict:
    """Return the latest cached disease diagnosis for a camera node, with
    treatment recommendations (recomputed from the label)."""
    NodeIdPath(node_id=node_id)
    diag = await cache.get_camera_diagnostics(node_id)
    issue = diag.get("issue", "None")
    healthy = issue in TreatmentDB.healthy_labels() or issue in ("None", "healthy")
    treatments = None
    if issue in TreatmentDB._MAPPING and not healthy:
        treatments = [
            {"type": t["type"], "actions": t["actions"]}
            for t in TreatmentDB.get(issue) or []
        ]
    return {
        "node_id": node_id,
        "issue": issue,
        "confidence": diag.get("confidence", 0.0),
        "timestamp": diag.get("timestamp"),
        "healthy": healthy,
        "treatments": treatments,
    }


# ---------- agronomist chat ----------

# Admin-only: chat spends metered cloud-API money; field devices have no
# reason to call it, and the per-IP rate limit alone can't stop a leaked
# device token from burning the quota.
@router.get(
    "/agronomist/chat",
    dependencies=[Depends(require_admin)],
)
@limiter.limit("5/minute")
async def stream_agronomist_chat(
    request: Request,
    node_id: str,
    user_query: str,
    cache: Cache = Depends(get_cache),
    chat: AgronomistChat = Depends(get_chat),
):
    NodeIdPath(node_id=node_id)

    # Validate and sanitize query
    ChatQuery(node_id=node_id, user_query=user_query)

    telemetry = await cache.get_all_telemetry(node_id)
    diagnostics = await cache.get_camera_diagnostics(node_id)

    try:
        prompt = chat.build_prompt(node_id, telemetry, diagnostics, user_query)
    except ValueError as exc:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=str(exc),
        ) from exc
    await logger.ainfo("agronomist_query", node_id=node_id, query_preview=user_query[:80])

    async def event_stream():
        async for chunk in chat.stream(prompt):
            yield chunk

    return StreamingResponse(event_stream(), media_type="text/event-stream")


# ---------- node pairing ----------

@router.post(
    "/node/{node_id}/hello",
    status_code=status.HTTP_201_CREATED,
)
async def register_node(
    node_id: str,
    request: Request,
    cache: Cache = Depends(get_cache),
    principal: Principal = Depends(require_auth),
) -> dict:
    """Pair a node with the system.

    Devices POST this once on first boot (or every cold boot — registration is
    idempotent) so the dashboard surfaces the card immediately, before any
    telemetry has arrived. The body may carry an optional ``kind`` field
    (e.g. ``"soil"``, ``"camera"``) plus a free-form ``label`` for the operator.
    """
    NodeIdPath(node_id=node_id)
    principal.assert_node(node_id)
    try:
        body = await request.json()
    except Exception:
        body = {}
    profile = {
        "kind": str(body.get("kind") or "unknown")[:32],
        "label": str(body.get("label") or "")[:64],
        "fw": str(body.get("firmware_version") or "")[:32],
    }
    await cache.register_node(node_id, profile=profile)
    if principal.is_admin:
        # Provisioning bootstrap: issue (or rotate) the node's own token.
        device_token = await cache.issue_device_token(node_id)
    else:
        # A device re-hello (cold boot) keeps its current token — rotating here
        # would brick the caller, which cannot store the response atomically
        # with the request (ESP32s discard the body on power blips).
        device_token = await cache.get_device_token(node_id)
    # Push to SSE so the dashboard places the card on screen immediately.
    await cache.publish_telemetry_stream({
        "node_id": node_id,
        "data": json.dumps({"online": True, "profile": profile}),
    })
    await logger.ainfo("node_registered", node_id=node_id, profile=profile)
    return {
        "status": "registered",
        "node_id": node_id,
        "profile": profile,
        "device_token": device_token,
    }


# ---------- device administration (admin token only) ----------

@router.get("/admin/devices", dependencies=[Depends(require_admin)])
async def list_devices(cache: Cache = Depends(get_cache)) -> dict:
    """List node ids that currently hold an issued per-device token."""
    return {"devices": await cache.list_device_tokens()}


@router.post("/node/{node_id}/revoke-token", dependencies=[Depends(require_admin)])
async def revoke_device_token(
    node_id: str,
    cache: Cache = Depends(get_cache),
) -> dict:
    """Revoke a node's device token (e.g. lost/compromised hardware). The node
    must re-provision via /hello with the admin token to get a new one."""
    NodeIdPath(node_id=node_id)
    revoked = await cache.revoke_device_token(node_id)
    return {"node_id": node_id, "revoked": revoked}


# ---------- telemetry read ----------

@router.get(
    "/nodes",
    dependencies=[Depends(require_auth)],
)
async def list_nodes(cache: Cache = Depends(get_cache)) -> dict:
    """List node ids known to the hub (paired + telemetry-bearing)."""
    return {"nodes": await cache.list_nodes()}


@router.get(
    "/node/{node_id}/telemetry",
    dependencies=[Depends(require_auth)],
)
async def latest_telemetry(
    node_id: str,
    cache: Cache = Depends(get_cache),
) -> dict:
    """Return the latest cached telemetry for a node, normalized for the client."""
    NodeIdPath(node_id=node_id)
    raw = await cache.get_all_telemetry(node_id)
    last_seen = await cache.get_last_seen(node_id)
    profile = await cache.get_node_profile(node_id)

    # Latest camera detection, if any (issue=="None" means no diagnosis yet).
    diag = await cache.get_camera_diagnostics(node_id)
    detection = None
    if diag and diag.get("issue") not in (None, "None"):
        detection = {
            "issue": diag["issue"],
            "confidence": diag.get("confidence"),
            "timestamp": diag.get("timestamp"),
        }

    # Actuator (irrigation zone) state, if this node is a controllable zone.
    zone_state = await cache.get_zone_state(node_id)
    actuator = None
    if zone_state:
        actuator = {
            "on": zone_state.get("on") == "1",
            "reason": zone_state.get("reason"),
            "bound": zone_state.get("bound"),
            "mode": zone_state.get("mode"),
        }

    def _as_float(value: str | None) -> float | None:
        if value is None:
            return None
        try:
            return float(value)
        except (TypeError, ValueError):
            return None

    return {
        "node_id": node_id,
        # Cache stores ambient temperature under the "temp" key; expose it as
        # "temperature" to match the telemetry ingestion schema and the client.
        "moisture": _as_float(raw.get("moisture")),
        "temperature": _as_float(raw.get("temp")),
        "ec": _as_float(raw.get("ec")),
        "battery_pct": _as_float(raw.get("battery_pct")),
        # Firmware health diagnostics (populated by the MQTT subscriber when
        # the ESP32 reports them). Used to render a "DIAG" badge on the card.
        "reset_reason": raw.get("reset_reason"),
        "free_heap": int(raw["free_heap"]) if raw.get("free_heap") else None,
        # Pairing metadata so the dashboard can show "STALE" for offline nodes
        # without removing the card from the grid.
        "last_seen": last_seen,
        "profile": profile or None,
        # Latest camera disease detection (camera nodes only).
        "detection": detection,
        # Irrigation actuator state (soil/zone nodes only).
        "actuator": actuator,
    }


# ---------- historical telemetry (InfluxDB) ----------

_HISTORY_FIELDS = {"moisture", "temperature", "ec", "battery_pct"}
# range -> (flux range start, downsample window)
_HISTORY_RANGES = {
    "1h": ("-1h", "1m"),
    "24h": ("-24h", "15m"),
    "7d": ("-7d", "1h"),
}


@router.get(
    "/node/{node_id}/history",
    dependencies=[Depends(require_auth)],
)
async def node_history(
    node_id: str,
    field: str = "moisture",
    range: str = "24h",
    tsdb: TimeSeriesDB = Depends(get_tsdb),
) -> dict:
    """Downsampled time-series for one field of one node, from InfluxDB.

    ``field`` and ``range`` are validated against fixed allowlists so the Flux
    query is not user-injectable.
    """
    NodeIdPath(node_id=node_id)
    if field not in _HISTORY_FIELDS:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=f"field must be one of {sorted(_HISTORY_FIELDS)}",
        )
    if range not in _HISTORY_RANGES:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=f"range must be one of {sorted(_HISTORY_RANGES)}",
        )
    range_start, window = _HISTORY_RANGES[range]
    try:
        series = await asyncio.to_thread(
            tsdb.query_series, node_id, field, range_start, window
        )
    except Exception as exc:
        await logger.aerror("history_query_failed", node_id=node_id, error=str(exc))
        series = []
    return {
        "node_id": node_id,
        "field": field,
        "range": range,
        "points": [{"t": t, "v": v} for t, v in series],
    }


# ---------- alerts ----------

@router.get("/alerts", dependencies=[Depends(require_auth)])
async def list_alerts(
    count: int = 50,
    cache: Cache = Depends(get_cache),
) -> dict:
    """Most recent alerts (offline / dry / battery / disease), newest first."""
    count = max(1, min(count, 200))
    return {"alerts": await cache.get_recent_alerts(count)}


# ---------- automation / closed-loop control ----------

_CONFIG_FIELDS = {
    "mode",
    "emergency_stop",
    "moisture_setpoint",
    "moisture_target",
    "max_run_seconds",
    "cooldown_seconds",
    "daily_cap_seconds",
}


@router.post("/zone/{zone}/command", dependencies=[Depends(require_admin)])
async def zone_command(
    zone: str,
    request: Request,
    engine: ControlEngine = Depends(get_control_engine),
) -> dict:
    """Manual actuator override (admin only). Body: {"action": "on" | "off"}.
    OFF is always honored; ON respects emergency-stop + daily cap."""
    NodeIdPath(node_id=zone)
    try:
        body = await request.json()
    except Exception:
        body = {}
    action = str(body.get("action", "")).lower()
    if action not in ("on", "off"):
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="action must be 'on' or 'off'",
        )
    result = await engine.manual_command(zone, action)
    await logger.ainfo("zone_command", zone=zone, action=action, result=result)
    return result


@router.get("/automation/config", dependencies=[Depends(require_auth)])
async def get_automation_config(
    engine: ControlEngine = Depends(get_control_engine),
) -> dict:
    """Effective automation config (settings defaults + operator overrides)."""
    return await engine.effective_config()


@router.put("/automation/config", dependencies=[Depends(require_admin)])
async def put_automation_config(
    request: Request,
    cache: Cache = Depends(get_cache),
) -> dict:
    """Update automation overrides: mode, emergency_stop, setpoints, interlocks."""
    try:
        body = await request.json()
    except Exception:
        body = {}
    updates = {k: v for k, v in body.items() if k in _CONFIG_FIELDS}
    if "mode" in updates and updates["mode"] not in ("advisory", "auto"):
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="mode must be 'advisory' or 'auto'",
        )
    if "emergency_stop" in updates:
        updates["emergency_stop"] = (
            1 if updates["emergency_stop"] in (True, 1, "1", "true", "True") else 0
        )
    await cache.update_automation_config(updates)
    await logger.ainfo("automation_config_updated", updates=list(updates.keys()))
    return {"updated": sorted(updates.keys())}


@router.get("/automation/log", dependencies=[Depends(require_auth)])
async def get_automation_log(
    count: int = 50,
    cache: Cache = Depends(get_cache),
) -> dict:
    """Recent automation decisions/actuations from the audit stream."""
    count = max(1, min(count, 200))
    return {"log": await cache.get_automation_log(count)}


# ---------- live telemetry stream (SSE) ----------

@router.get(
    "/stream",
    dependencies=[Depends(require_auth)],
)
async def telemetry_stream(cache: Cache = Depends(get_cache)) -> StreamingResponse:
    """Server-Sent Events feed of every telemetry update.

    The MQTT subscriber and HTTP telemetry endpoint both XADD to the
    ``stream:telemetry`` Redis stream. This endpoint tails it with XREAD
    and re-emits each entry as an SSE event so the dashboard can update
    cards in real time without polling.
    """

    async def event_stream():
        r = cache._text_redis()  # internal — bypass for a low-level XREAD
        last_id = "$"  # only emit entries that arrive after the connection opens
        # Heartbeat keeps proxies/clients from timing out an idle connection.
        last_heartbeat = time.monotonic()
        try:
            while True:
                resp = await r.xread(
                    streams={"stream:telemetry": last_id},
                    count=20,
                    block=15000,  # ms — XREAD returns when a message arrives or 15s elapses
                )
                if resp:
                    for _stream, entries in resp:
                        for entry_id, fields in entries:
                            last_id = entry_id
                            # Redis stream fields are flat strings; the original
                            # nested payload was JSON-encoded into the "data" field.
                            payload = {
                                "node_id": fields.get("node_id"),
                                "data": json.loads(fields.get("data", "{}")),
                            }
                            yield f"data: {json.dumps(payload)}\n\n"
                now = time.monotonic()
                if now - last_heartbeat > 20:
                    yield ": keepalive\n\n"
                    last_heartbeat = now
        except asyncio.CancelledError:
            # Client disconnected — exit cleanly
            return

    return StreamingResponse(
        event_stream(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "X-Accel-Buffering": "no",  # disable buffering at the proxy layer
        },
    )


# ---------- telemetry ingestion ----------

@router.post(
    "/telemetry",
    status_code=status.HTTP_202_ACCEPTED,
)
async def ingest_telemetry(
    payload: TelemetryPayload,
    cache: Cache = Depends(get_cache),
    tsdb: TimeSeriesDB = Depends(get_tsdb),
    principal: Principal = Depends(require_auth),
):
    # A device token may only report as its own node — no spoofing a
    # neighbouring zone into auto-irrigation.
    principal.assert_node(payload.node_id)
    # Auto-pair: any HTTP telemetry source counts as a registered device.
    # Keeps the card on the dashboard even after the cache TTL expires.
    await cache.register_node(payload.node_id)

    fields: dict[str, float] = {}
    if payload.moisture is not None:
        await cache.set_telemetry(payload.node_id, "moisture", payload.moisture)
        fields["moisture"] = payload.moisture
    if payload.temperature is not None:
        await cache.set_telemetry(payload.node_id, "temp", payload.temperature)
        fields["temperature"] = payload.temperature
    if payload.ec is not None:
        await cache.set_telemetry(payload.node_id, "ec", payload.ec)
        fields["ec"] = payload.ec
    if payload.battery_pct is not None:
        await cache.set_telemetry(payload.node_id, "battery_pct", payload.battery_pct)
        fields["battery_pct"] = payload.battery_pct

    # Stream to Redis for real-time consumers
    await cache.publish_telemetry_stream({
        "node_id": payload.node_id,
        "data": json.dumps(fields),
    })

    # Persist to InfluxDB. The influxdb-client write is synchronous (blocking I/O),
    # so run it in a thread to avoid stalling the event loop for every other request.
    try:
        await asyncio.to_thread(tsdb.write_telemetry, payload.node_id, fields)
    except Exception as exc:
        await logger.aerror("influxdb_write_failed", node_id=payload.node_id, error=str(exc))
        # Accept the request; cache has the latest values. Alerting should monitor DB health.

    await logger.ainfo("telemetry_ingested", node_id=payload.node_id, fields=list(fields.keys()))
    # Return a plain dict so the route's declared 202 status code applies. An
    # explicit JSONResponse would reset the status to 200.
    return {"status": "accepted", "node_id": payload.node_id}
