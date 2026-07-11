"""External service clients and business logic utilities."""
from __future__ import annotations

import asyncio
import io
import json
import logging
import secrets
import time
from typing import AsyncIterator

import httpx
import numpy as np
import paho.mqtt.client as mqtt
import redis.asyncio as redis
from PIL import Image
from influxdb_client import InfluxDBClient, Point
from influxdb_client.client.write_api import SYNCHRONOUS

from config import Settings, get_settings

_log = logging.getLogger(__name__)


def utc_now_iso() -> str:
    """The wire timestamp format for alerts, detections, and the audit log."""
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


class Cache:
    """Async Redis cache wrapper with namespaced keys."""

    def __init__(self, settings: Settings):
        self._settings = settings
        self._r: redis.Redis | None = None
        self._rb: redis.Redis | None = None

    def _text_redis(self) -> redis.Redis:
        if self._r is None:
            self._r = redis.Redis(
                host=self._settings.redis_host,
                port=self._settings.redis_port,
                db=self._settings.redis_db,
                password=self._settings.redis_password or None,
                decode_responses=True,
            )
        return self._r

    def _binary_redis(self) -> redis.Redis:
        if self._rb is None:
            self._rb = redis.Redis(
                host=self._settings.redis_host,
                port=self._settings.redis_port,
                db=self._settings.redis_db,
                password=self._settings.redis_password or None,
                decode_responses=False,
            )
        return self._rb

    # ---------- telemetry ----------
    async def set_telemetry(self, node_id: str, field: str, value: str | float, ttl: int = 86400) -> None:
        await self._text_redis().set(f"telemetry:{node_id}:{field}", str(value), ex=ttl)

    async def get_all_telemetry(self, node_id: str) -> dict[str, str]:
        # SCAN instead of KEYS: KEYS is O(N) over the whole keyspace and blocks
        # Redis for the duration, which does not scale as node count grows.
        r = self._text_redis()
        pattern = f"telemetry:{node_id}:*"
        keys = [key async for key in r.scan_iter(match=pattern, count=100)]
        if not keys:
            return {}
        values = await r.mget(keys)
        prefix = f"telemetry:{node_id}:"
        return {k.removeprefix(prefix): v for k, v in zip(keys, values) if v is not None}

    async def list_nodes(self) -> list[str]:
        """Return the union of registered nodes and nodes with cached telemetry.

        Registered nodes (paired devices) persist on the dashboard even if their
        telemetry TTL has expired — operators expect every paired plant to keep
        its card. Telemetry-only nodes are still listed so unregistered demo
        seeds remain visible.
        """
        r = self._text_redis()
        # Registered set is the authoritative pairing record.
        registered = set(await r.smembers("nodes:registered"))
        async for key in r.scan_iter(match="telemetry:*", count=200):
            parts = key.split(":")
            if len(parts) >= 3:
                registered.add(parts[1])
        return sorted(registered)

    async def register_node(self, node_id: str, profile: dict | None = None) -> None:
        """Persistently pair a node with the system.

        Called when a device sends a wake-up hello, or implicitly when the MQTT
        subscriber ingests the first telemetry payload for a previously unseen
        node id. Registration is permanent (no TTL) so the dashboard card never
        disappears even if telemetry stops arriving.
        """
        r = self._text_redis()
        await r.sadd("nodes:registered", node_id)
        if profile:
            await r.hset(f"nodes:profile:{node_id}", mapping={
                k: str(v) for k, v in profile.items() if v is not None
            })
        # Track last-seen so the dashboard can dim stale cards.
        await r.set(f"nodes:last_seen:{node_id}", str(int(time.time())))

    async def note_node_seen(
        self, node_id: str, default_profile: dict | None = None
    ) -> None:
        """Idempotent 'this node exists' marker for ingest paths.

        Unlike register_node this never overwrites an existing profile and
        never touches last_seen — a retained MQTT message or a detection must
        not make a dead node look alive or flip its kind.
        """
        r = self._text_redis()
        await r.sadd("nodes:registered", node_id)
        if default_profile:
            for k, v in default_profile.items():
                if v is not None:
                    await r.hsetnx(f"nodes:profile:{node_id}", k, str(v))

    async def touch_node(self, node_id: str) -> None:
        """Update the last-seen timestamp without changing the profile."""
        await self._text_redis().set(
            f"nodes:last_seen:{node_id}", str(int(time.time()))
        )

    async def get_node_profile(self, node_id: str) -> dict[str, str]:
        return await self._text_redis().hgetall(f"nodes:profile:{node_id}")

    async def get_last_seen(self, node_id: str) -> int | None:
        v = await self._text_redis().get(f"nodes:last_seen:{node_id}")
        return int(v) if v else None

    # ---------- per-device auth tokens ----------
    # Each field device gets its own 256-bit bearer token, so a single leaked
    # node credential can be revoked without rotating every device. The shared
    # admin token (settings.api_auth_token) remains valid for the dashboard/ops
    # and is the bootstrap key a device presents once to /hello to be issued its
    # own token. Stored as: hash auth:devicetokens {token -> node_id} for O(1)
    # verification, plus a reverse key per node so rotation/revocation is cheap.
    async def issue_device_token(self, node_id: str) -> str:
        r = self._text_redis()
        old = await r.get(f"auth:devicetoken:{node_id}")
        if old:
            await r.hdel("auth:devicetokens", old)  # rotate: drop the prior token
        token = secrets.token_urlsafe(32)
        await r.hset("auth:devicetokens", token, node_id)
        await r.set(f"auth:devicetoken:{node_id}", token)
        return token

    async def verify_device_token(self, token: str) -> str | None:
        """Return the node_id a device token belongs to, or None if unknown."""
        if not token:
            return None
        return await self._text_redis().hget("auth:devicetokens", token)

    async def get_device_token(self, node_id: str) -> str | None:
        """Current token for a node (reverse index), or None if never issued."""
        return await self._text_redis().get(f"auth:devicetoken:{node_id}")

    # ---------- controller (actuator hardware) liveness ----------
    # A zone counts as hardware-bound only while a controller node keeps
    # heartbeating on pms/status/{node_id}. Inferring it from the API's own
    # broker connection lied whenever Mosquitto was up but no relay existed.
    async def set_controller_seen(self, zone: str) -> None:
        await self._text_redis().set(
            f"controller:last_seen:{zone}", str(int(time.time()))
        )

    async def controller_alive(self, zone: str, max_age_seconds: int) -> bool:
        v = await self._text_redis().get(f"controller:last_seen:{zone}")
        return bool(v) and (int(time.time()) - int(v)) <= max_age_seconds

    async def revoke_device_token(self, node_id: str) -> bool:
        r = self._text_redis()
        old = await r.get(f"auth:devicetoken:{node_id}")
        if not old:
            return False
        await r.hdel("auth:devicetokens", old)
        await r.delete(f"auth:devicetoken:{node_id}")
        return True

    async def list_device_tokens(self) -> list[str]:
        """Node ids that currently hold an issued device token."""
        r = self._text_redis()
        nodes: list[str] = []
        async for key in r.scan_iter(match="auth:devicetoken:*", count=100):
            nodes.append(key.removeprefix("auth:devicetoken:"))
        return sorted(nodes)

    # ---------- alerts ----------
    async def add_alert(self, alert: dict) -> None:
        entry = {k: str(v) for k, v in alert.items() if v is not None}
        await self._text_redis().xadd(
            "stream:alerts", entry, maxlen=2000, approximate=True
        )

    async def get_recent_alerts(self, count: int = 50) -> list[dict]:
        entries = await self._text_redis().xrevrange("stream:alerts", count=count)
        return [{**fields, "id": entry_id} for entry_id, fields in entries]

    async def is_alert_active(self, node_id: str, kind: str) -> bool:
        return bool(
            await self._text_redis().sismember("alerts:active", f"{node_id}:{kind}")
        )

    async def get_active_alerts(self) -> set[str]:
        """All active '{node}:{kind}' markers in one round-trip (scan batching)."""
        return set(await self._text_redis().smembers("alerts:active"))

    async def set_alert_active(self, node_id: str, kind: str, active: bool) -> None:
        r = self._text_redis()
        member = f"{node_id}:{kind}"
        if active:
            await r.sadd("alerts:active", member)
        else:
            await r.srem("alerts:active", member)

    # ---------- automation config + actuator (zone) state ----------
    async def get_automation_config(self) -> dict[str, str]:
        """Operator-set automation overrides (mode, emergency_stop, setpoints).
        The ControlEngine merges these over the settings defaults."""
        return await self._text_redis().hgetall("automation:config")

    async def update_automation_config(self, updates: dict) -> None:
        if updates:
            await self._text_redis().hset(
                "automation:config",
                mapping={k: str(v) for k, v in updates.items()},
            )

    async def get_zone_state(self, zone: str) -> dict[str, str]:
        return await self._text_redis().hgetall(f"zone:state:{zone}")

    async def set_zone_state(self, zone: str, fields: dict) -> None:
        await self._text_redis().hset(
            f"zone:state:{zone}",
            mapping={k: str(v) for k, v in fields.items()},
        )

    async def get_automation_log(self, count: int = 50) -> list[dict]:
        """Recent automation decisions/actuations from the audit stream."""
        entries = await self._text_redis().xrevrange("logs:automation", count=count)
        return [{**fields, "id": entry_id} for entry_id, fields in entries]

    # ---------- camera ----------
    async def set_camera_frame(self, node_id: str, data: bytes, ttl: int = 300) -> None:
        await self._binary_redis().set(f"camera:{node_id}:latest", data, ex=ttl)

    async def get_camera_frame(self, node_id: str) -> bytes | None:
        return await self._binary_redis().get(f"camera:{node_id}:latest")

    async def set_camera_diagnostics(self, node_id: str, payload: dict, ttl: int = 86400) -> None:
        await self._text_redis().set(f"camera:{node_id}:diagnostics", json.dumps(payload), ex=ttl)

    async def get_camera_diagnostics(self, node_id: str) -> dict:
        raw = await self._text_redis().get(f"camera:{node_id}:diagnostics")
        if not raw:
            return {"issue": "None", "confidence": 0.0}
        try:
            return json.loads(raw)
        except json.JSONDecodeError:
            return {"issue": "None", "confidence": 0.0}

    # ---------- automation safety log ----------
    async def log_automation_decision(self, node_id: str, decision: str, context: dict) -> None:
        # Redis stream fields must be flat scalars; serialize the nested context
        # to a JSON string rather than passing a dict (which raises DataError).
        entry = {
            "timestamp": utc_now_iso(),
            "node_id": node_id,
            "decision": decision,
            "context": json.dumps(context),
        }
        await self._text_redis().xadd("logs:automation", entry, maxlen=10000, approximate=True)

    EVENT_TYPES = ("telemetry", "alert", "detection", "actuator", "online")

    async def emit_event(self, event_type: str, node_id: str, payload: dict) -> None:
        """Single door onto the SSE stream — every event is a typed envelope.

        The dashboard dispatches on ``data.type`` instead of sniffing payload
        keys, and only ``telemetry`` events count as device liveness.
        """
        if event_type not in self.EVENT_TYPES:
            raise ValueError(f"unknown event type: {event_type}")
        await self._text_redis().xadd(
            "stream:telemetry",
            {
                "node_id": node_id,
                "data": json.dumps({"type": event_type, "payload": payload}),
            },
            maxlen=50000,
            approximate=True,
        )


class TimeSeriesDB:
    """InfluxDB wrapper for telemetry persistence."""

    def __init__(self, settings: Settings):
        self.client = InfluxDBClient(
            url=settings.influxdb_url,
            token=settings.influxdb_token,
            org=settings.influxdb_org,
        )
        self.write_api = self.client.write_api(write_options=SYNCHRONOUS)
        self.query_api = self.client.query_api()
        self.bucket = settings.influxdb_bucket
        self.org = settings.influxdb_org

    def write_telemetry(self, node_id: str, fields: dict[str, float]) -> None:
        point = Point("telemetry").tag("node_id", node_id)
        for k, v in fields.items():
            if v is not None:
                point = point.field(k, float(v))
        self.write_api.write(bucket=self.bucket, org=self.org, record=point)

    def query_series(
        self,
        node_id: str,
        field: str,
        range_start: str,
        window: str,
        max_points: int = 720,
    ) -> list[tuple[str, float]]:
        """Return [(iso_time, value), ...] for one field of one node, downsampled.

        Caller validates ``field`` and ``range_start``/``window`` against fixed
        allowlists (route layer), so the Flux string is not user-injectable.
        Blocking I/O — call via ``asyncio.to_thread``.
        """
        flux = (
            f'from(bucket: "{self.bucket}")'
            f' |> range(start: {range_start})'
            f' |> filter(fn: (r) => r._measurement == "telemetry")'
            f' |> filter(fn: (r) => r.node_id == "{node_id}")'
            f' |> filter(fn: (r) => r._field == "{field}")'
            f' |> aggregateWindow(every: {window}, fn: mean, createEmpty: false)'
            f' |> limit(n: {max_points})'
        )
        tables = self.query_api.query(flux, org=self.org)
        out: list[tuple[str, float]] = []
        for table in tables:
            for record in table.records:
                value = record.get_value()
                if value is not None:
                    out.append((record.get_time().isoformat(), float(value)))
        return out

    def close(self) -> None:
        self.client.close()


# Coarse disease groups. The crop is already known from which node/camera a
# frame came from, so the classifier only needs the KIND of problem — which is
# what drives the response. Grouping also collapses the near-identical fine
# classes the model kept confusing (potato early vs late blight; tomato
# bacterial vs septoria vs target spot), lifting field accuracy from ~44%
# (15-way) to ~75% (5 groups) on the very same model, via summed group softmax.
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
GROUP_OF: dict[str, str] = {f: g for g, fs in COARSE_GROUPS.items() for f in fs}
GROUP_DISPLAY: dict[str, str] = {
    "healthy": "Healthy",
    "blight": "Blight",
    "leaf_spot": "Leaf Spot",
    "viral": "Viral Infection",
    "pest": "Pest Damage",
}


class InferenceEngine:
    """ONNX-based PlantVillage ResNet18 classifier with safe fallback when model is absent."""

    IMAGENET_MEAN = np.array([0.485, 0.456, 0.406], dtype=np.float32).reshape(1, 3, 1, 1)
    IMAGENET_STD = np.array([0.229, 0.224, 0.225], dtype=np.float32).reshape(1, 3, 1, 1)
    DEFAULT_INPUT_SIZE = (128, 128)

    def __init__(self, settings: Settings):
        self.model_path = settings.model_path
        self.labels = list(settings.class_labels)
        # Indices of each coarse group's fine classes present in this model.
        # Empty (skipped) for a model whose labels aren't the PlantVillage set —
        # grouped inference then falls back to the fine label.
        self._group_indices = {
            g: [i for i, lbl in enumerate(self.labels) if GROUP_OF.get(lbl) == g]
            for g in COARSE_GROUPS
        }
        self._group_indices = {g: idx for g, idx in self._group_indices.items() if idx}
        self.session = None
        self.provider = "none"
        # Derived from the model's own input shape at load (see below) so a new
        # export at a different resolution (e.g. the 224px field model) drops in
        # with no code change. Falls back to the legacy 128 if the model uses a
        # dynamic spatial axis.
        self.input_size = self.DEFAULT_INPUT_SIZE
        if self.model_path.exists():
            try:
                import onnxruntime as ort

                opts = ort.SessionOptions()
                opts.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
                # Prefer the GPU on the Jetson (TensorRT > CUDA), fall back to CPU
                # on the dev box / Pi. onnxruntime only exposes a provider when its
                # build supports it, so this selects GPU automatically where present
                # and is a no-op CPU path everywhere else.
                available = ort.get_available_providers()
                preferred = [
                    "TensorrtExecutionProvider",
                    "CUDAExecutionProvider",
                    "CPUExecutionProvider",
                ]
                providers = [p for p in preferred if p in available] or [
                    "CPUExecutionProvider"
                ]
                self.session = ort.InferenceSession(
                    str(self.model_path),
                    sess_options=opts,
                    providers=providers,
                )
                self.provider = self.session.get_providers()[0]
                # Read spatial dims from the graph input [N, C, H, W]. Only adopt
                # them when they are concrete ints (a dynamic axis is a str).
                shape = self.session.get_inputs()[0].shape
                if len(shape) == 4 and isinstance(shape[2], int) and isinstance(shape[3], int):
                    self.input_size = (shape[3], shape[2])  # PIL wants (W, H)
                logging.getLogger(__name__).info(
                    "onnx_session_ready provider=%s input_size=%s",
                    self.provider, self.input_size,
                )
            except Exception as exc:  # pragma: no cover - logged at startup
                logging.getLogger(__name__).warning(
                    "Failed to load ONNX model at %s: %s", self.model_path, exc
                )
        else:
            logging.getLogger(__name__).warning(
                "Model file not found at %s. Inference will return 'model_unavailable'.",
                self.model_path,
            )

    def _preprocess(self, image_bytes: bytes) -> np.ndarray:
        img = Image.open(io.BytesIO(image_bytes)).convert("RGB")
        img = img.resize(self.input_size)
        arr = np.array(img).astype(np.float32) / 255.0  # HWC, 0-1
        arr = np.transpose(arr, (2, 0, 1))  # CHW
        arr = np.expand_dims(arr, axis=0)  # NCHW
        arr = (arr - self.IMAGENET_MEAN) / self.IMAGENET_STD
        return arr

    def _infer_probs(self, image_bytes: bytes) -> np.ndarray | None:
        """Run the model and return the softmax probability vector, or None if
        the model is absent or the output shape doesn't match the labels."""
        tensor = self._preprocess(image_bytes)
        input_name = self.session.get_inputs()[0].name
        out = self.session.run(None, {input_name: tensor})[0]
        if out.ndim == 2 and out.shape[1] == len(self.labels):
            return self._softmax(out[0])
        return None

    def predict(self, image_bytes: bytes) -> tuple[str, float]:
        """Fine-grained prediction: (label, confidence)."""
        if self.session is None:
            return ("model_unavailable", 0.0)
        probs = self._infer_probs(image_bytes)
        if probs is None:
            return ("unknown_format", 0.0)
        best_idx = int(np.argmax(probs))
        label = self.labels[best_idx] if 0 <= best_idx < len(self.labels) else "unknown"
        return (label, float(probs[best_idx]))

    def predict_grouped(self, image_bytes: bytes) -> tuple[str, float, str, float]:
        """Coarse diagnosis by summing softmax over each group's fine classes.

        Returns (group_key, group_confidence, fine_label, fine_confidence). The
        group is far more accurate in the field than the fine label, so it drives
        the diagnosis + treatment; the fine label is kept as detail. Falls back to
        the fine label as its own group for a non-PlantVillage model.
        """
        if self.session is None:
            return ("model_unavailable", 0.0, "model_unavailable", 0.0)
        probs = self._infer_probs(image_bytes)
        if probs is None:
            return ("unknown_format", 0.0, "unknown_format", 0.0)
        best_idx = int(np.argmax(probs))
        fine = self.labels[best_idx] if 0 <= best_idx < len(self.labels) else "unknown"
        fine_conf = float(probs[best_idx])
        if not self._group_indices:
            return (fine, fine_conf, fine, fine_conf)
        group_probs = {g: float(probs[idx].sum()) for g, idx in self._group_indices.items()}
        group = max(group_probs, key=group_probs.__getitem__)
        return (group, group_probs[group], fine, fine_conf)

    @staticmethod
    def _softmax(x: np.ndarray) -> np.ndarray:
        e = np.exp(x - np.max(x))
        return e / e.sum()


class TreatmentDB:
    """Static treatment recommendations keyed by PlantVillage class label.

    Values are agronomy-aware suggestions assembled from extension-office
    guidelines. No pesticide dosage is given; the operator must consult local
    regulations and product labels.
    """

    _MAPPING: dict[str, list[dict]] = {
        "Pepper__bell___Bacterial_spot": [
            {"type": "cultural", "actions": ["Remove and destroy infected leaves.", "Avoid overhead irrigation; water at the base.", "Rotate with non-solanaceous crops."]},
            {"type": "chemical", "actions": ["Apply copper-based bactericide according to label.", "Start sprays before symptoms spread."]},
        ],
        "Pepper__bell___healthy": [
            {"type": "none", "actions": ["Crop appears healthy. Continue current cultural practices and monitoring."]},
        ],
        "Potato___Early_blight": [
            {"type": "cultural", "actions": ["Remove lower infected foliage and volunteer plants.", "Ensure adequate but not excessive nitrogen.", "Rotate crops away from solanaceous species."]},
            {"type": "chemical", "actions": ["Apply fungicides containing chlorothalonil or mancozeb.", "Repeat on a 7-14 day schedule during humid periods."]},
        ],
        "Potato___Late_blight": [
            {"type": "cultural", "actions": ["Destroy heavily infected plants (do not compost).", "Increase row spacing for airflow.", "Eliminate volunteer potatoes and nightshade weeds."]},
            {"type": "chemical", "actions": ["Apply protectant fungicide (mancozeb) before wet periods.", "Use systemic products (e.g., metalaxyl) only if label permits."]},
        ],
        "Potato___healthy": [
            {"type": "none", "actions": ["Crop appears healthy. Maintain hilling and irrigation scheduling."]},
        ],
        "Tomato_Bacterial_spot": [
            {"type": "cultural", "actions": ["Prune infected leaves with sanitized tools.", "Avoid working in wet canopies.", "Use drip irrigation if available."]},
            {"type": "chemical", "actions": ["Apply copper-based sprays early in the season.", "Repeat per label during wet weather."]},
        ],
        "Tomato_Early_blight": [
            {"type": "cultural", "actions": ["Mulch around plants to limit soil splash.", "Remove lower infected leaves.", "Rotate tomatoes with grasses or legumes."]},
            {"type": "chemical", "actions": ["Apply fungicides with chlorothalonil or copper.", "Begin sprays at first fruit set."]},
        ],
        "Tomato_Late_blight": [
            {"type": "cultural", "actions": ["Remove and bag infected tissue immediately.", "Space plants for rapid leaf drying.", "Avoid evening irrigation."]},
            {"type": "chemical", "actions": ["Apply copper or chlorothalonil before infection periods.", "Use systemic fungicides only per local label."]},
        ],
        "Tomato_Leaf_Mold": [
            {"type": "cultural", "actions": ["Increase greenhouse ventilation or plant spacing.", "Keep humidity below 85%.", "Remove senescent lower leaves."]},
            {"type": "chemical", "actions": ["Apply registered fungicides if cultural control is insufficient."]},
        ],
        "Tomato_Septoria_leaf_spot": [
            {"type": "cultural", "actions": ["Remove bottom leaves as plants grow.", "Stake or cage to improve airflow.", "Eliminate tomato debris after harvest."]},
            {"type": "chemical", "actions": ["Apply fungicides containing chlorothalonil or mancozeb.", "Rotate chemistries to avoid resistance."]},
        ],
        "Tomato_Spider_mites_Two_spotted_spider_mite": [
            {"type": "cultural", "actions": ["Wash foliage with a strong water jet.", "Increase humidity around plants.", "Remove heavily infested leaves."]},
            {"type": "chemical", "actions": ["Apply miticide if infestation is severe; note miticides often do not affect eggs."]},
            {"type": "biological", "actions": ["Introduce predatory mites (Phytoseiulus persimilis) in protected culture."]},
        ],
        "Tomato__Target_Spot": [
            {"type": "cultural", "actions": ["Remove infected lower leaves.", "Avoid overhead irrigation.", "Rotate out of solanaceous crops."]},
            {"type": "chemical", "actions": ["Apply protectant fungicides during fruiting.", "Follow label for re-entry and pre-harvest intervals."]},
        ],
        "Tomato__Tomato_YellowLeaf__Curl_Virus": [
            {"type": "cultural", "actions": ["Uproot and destroy infected plants immediately.", "Use fine insect netting to exclude whiteflies.", "Plant TYLCV-resistant varieties where available."]},
            {"type": "chemical", "actions": ["Control whitefly vectors with approved insecticides.", "Use yellow sticky traps for monitoring."]},
        ],
        "Tomato__Tomato_mosaic_virus": [
            {"type": "cultural", "actions": ["Remove and destroy symptomatic plants.", "Wash hands and sanitize tools between plants.", "Avoid tobacco use near the crop."]},
            {"type": "chemical", "actions": ["There is no cure; focus on vector and sanitation control."]},
        ],
        "Tomato_healthy": [
            {"type": "none", "actions": ["Crop appears healthy. Continue monitoring and standard care."]},
        ],
    }

    @classmethod
    def get(cls, label: str) -> list[dict] | None:
        return cls._MAPPING.get(label)

    @classmethod
    def healthy_labels(cls) -> set[str]:
        return {k for k in cls._MAPPING if "healthy" in k.lower()}

    @classmethod
    def treatments_for(cls, label: str) -> list[dict] | None:
        """Client-shaped treatment list for a diseased label, else None.

        The single place that encodes 'healthy/unknown labels get no
        treatments' — routes must not reach into _MAPPING themselves.
        """
        if label not in cls._MAPPING or label in cls.healthy_labels():
            return None
        return [
            {"type": t["type"], "actions": t["actions"]}
            for t in cls._MAPPING[label]
        ]

    # Group-level guidance, keyed by COARSE_GROUPS key. Coarser than the per-label
    # advice but matched to the accurate grouped diagnosis; the exact pathogen
    # within a group is left to the operator (bacterial vs fungal spot, etc.).
    _GROUP_MAPPING: dict[str, list[dict]] = {
        "blight": [
            {"type": "cultural", "actions": ["Remove and destroy infected foliage (do not compost).", "Improve spacing/airflow and avoid evening irrigation.", "Rotate away from solanaceous crops."]},
            {"type": "chemical", "actions": ["Apply a protectant fungicide (chlorothalonil or mancozeb) before wet periods.", "Repeat on a 7-14 day schedule in humid weather."]},
        ],
        "leaf_spot": [
            {"type": "cultural", "actions": ["Prune infected lower leaves with sanitized tools.", "Avoid overhead irrigation and working in wet canopies.", "Remove crop debris after harvest."]},
            {"type": "chemical", "actions": ["Copper-based sprays for bacterial spot; chlorothalonil/mancozeb for fungal spots.", "Confirm the pathogen, then rotate chemistries to avoid resistance."]},
        ],
        "viral": [
            {"type": "cultural", "actions": ["Uproot and destroy symptomatic plants immediately.", "Exclude/control insect vectors (whitefly) with netting and sticky traps.", "Sanitize hands and tools; plant resistant varieties."]},
            {"type": "chemical", "actions": ["No chemical cure — focus on vector and sanitation control."]},
        ],
        "pest": [
            {"type": "cultural", "actions": ["Dislodge mites with a strong water jet and raise humidity.", "Remove heavily infested leaves."]},
            {"type": "chemical", "actions": ["Apply a miticide if severe; note many miticides miss eggs, so repeat per label."]},
            {"type": "biological", "actions": ["Introduce predatory mites (Phytoseiulus persimilis) under protected culture."]},
        ],
    }

    @classmethod
    def is_healthy_group(cls, group: str) -> bool:
        return group == "healthy"

    @classmethod
    def treatments_for_group(cls, group: str) -> list[dict] | None:
        """Client-shaped treatment list for a coarse group, else None (healthy/unknown)."""
        entries = cls._GROUP_MAPPING.get(group)
        if entries is None:
            return None
        return [{"type": t["type"], "actions": t["actions"]} for t in entries]


class AgronomistChat:
    """Cloud LLM chat supporting Gemini (free tier) and Anthropic Claude (production).

    The rest of the system runs fully offline; only this class calls an external API.
    Provider is selected via CHAT_PROVIDER env var ("gemini" | "anthropic").
    """

    JAILBREAK_PATTERNS = [
        "ignore previous instructions",
        "ignore the above",
        "you are not",
        "system prompt",
        "new instructions",
        "disregard",
    ]

    SYSTEM_PROMPT = (
        "You are an expert commercial agronomist assistant monitoring an automated farm grid. "
        "Use only the sensor context provided. Keep responses concise and actionable. "
        "If context is insufficient, ask a clarifying question."
    )

    _SUPPORTED_PROVIDERS = ("gemini", "anthropic")

    def __init__(self, settings: Settings):
        self._provider = settings.chat_provider
        if self._provider not in self._SUPPORTED_PROVIDERS:
            raise ValueError(
                f"Unknown chat_provider {self._provider!r}. "
                f"Supported: {self._SUPPORTED_PROVIDERS}"
            )
        self._timeout = settings.chat_timeout
        if self._provider == "gemini":
            self._api_key = settings.gemini_api_key
            self._model = settings.gemini_model
        else:
            self._api_key = settings.anthropic_api_key
            self._model = settings.anthropic_model

    @classmethod
    def _sanitize_for_prompt(cls, text: str) -> str:
        lower = text.lower()
        for pattern in cls.JAILBREAK_PATTERNS:
            if pattern in lower:
                raise ValueError(f"Query rejected due to disallowed pattern: {pattern!r}")
        text = text.replace("<", "\uFF1C").replace(">", "\uFF1E")
        return text[:2048]

    def build_prompt(self, node_id: str, telemetry: dict, diagnostics: dict, user_query: str) -> str:
        safe_query = self._sanitize_for_prompt(user_query)
        return (
            f"Node: {node_id}\n"
            f"Volumetric Soil Moisture: {telemetry.get('moisture', 'N/A')}%\n"
            f"Ambient Temperature: "
            f"{telemetry.get('temperature', telemetry.get('temp', 'N/A'))} C\n"
            f"Electrical Conductivity: {telemetry.get('ec', 'N/A')} mS/cm\n"
            f"Battery: {telemetry.get('battery_pct', 'N/A')}%\n"
            f"Vision Diagnostics: {diagnostics}\n\n"
            f"Question: {safe_query}"
        )

    async def stream(self, prompt: str) -> AsyncIterator[str]:
        if self._provider == "gemini":
            async for token in self._stream_gemini(prompt):
                yield token
        else:
            async for token in self._stream_anthropic(prompt):
                yield token

    async def _stream_gemini(self, prompt: str) -> AsyncIterator[str]:
        """Gemini SSE streaming via Google AI REST API (v1beta)."""
        if not self._api_key:
            yield "[Chat unavailable: GEMINI_API_KEY not set]"
            return
        url = (
            f"https://generativelanguage.googleapis.com/v1beta"
            f"/models/{self._model}:streamGenerateContent"
        )
        payload = {
            "system_instruction": {"parts": [{"text": self.SYSTEM_PROMPT}]},
            "contents": [{"role": "user", "parts": [{"text": prompt}]}],
            "generationConfig": {"temperature": 0.3, "maxOutputTokens": 1024},
        }
        async with httpx.AsyncClient(timeout=self._timeout) as client:
            async with client.stream(
                "POST", url, json=payload,
                params={"key": self._api_key, "alt": "sse"},
            ) as response:
                if response.status_code != 200:
                    # Surface what Gemini actually said \u2014 model-not-found,
                    # invalid key, quota exceeded, etc. The default error was
                    # opaque and hid the real cause from users.
                    body = await response.aread()
                    detail = body.decode("utf-8", errors="replace")[:400]
                    _log.warning(
                        "gemini_api_error status=%s model=%s body=%s",
                        response.status_code, self._model, detail,
                    )
                    yield (
                        f"[Chat error: Gemini returned HTTP {response.status_code}. "
                        f"Model={self._model}. Detail: {detail}]"
                    )
                    return
                async for line in response.aiter_lines():
                    if not line.startswith("data: "):
                        continue
                    data = line.removeprefix("data: ").strip()
                    if not data or data == "[DONE]":
                        continue
                    try:
                        obj = json.loads(data)
                        text = obj["candidates"][0]["content"]["parts"][0]["text"]
                        if text:
                            yield text
                    except (json.JSONDecodeError, KeyError, IndexError):
                        continue

    async def _stream_anthropic(self, prompt: str) -> AsyncIterator[str]:
        """Anthropic Claude SSE streaming via Messages API."""
        if not self._api_key:
            yield "[Chat unavailable: ANTHROPIC_API_KEY not set]"
            return
        headers = {
            "x-api-key": self._api_key,
            "anthropic-version": "2023-06-01",
            "content-type": "application/json",
        }
        payload = {
            "model": self._model,
            "max_tokens": 1024,
            "system": self.SYSTEM_PROMPT,
            "messages": [{"role": "user", "content": prompt}],
            "stream": True,
        }
        async with httpx.AsyncClient(timeout=self._timeout) as client:
            async with client.stream(
                "POST", "https://api.anthropic.com/v1/messages",
                headers=headers, json=payload,
            ) as response:
                if response.status_code != 200:
                    body = await response.aread()
                    detail = body.decode("utf-8", errors="replace")[:400]
                    _log.warning(
                        "anthropic_api_error status=%s model=%s body=%s",
                        response.status_code, self._model, detail,
                    )
                    yield (
                        f"[Chat error: Anthropic returned HTTP {response.status_code}. "
                        f"Model={self._model}. Detail: {detail}]"
                    )
                    return
                async for line in response.aiter_lines():
                    if not line.startswith("data: "):
                        continue
                    data = line.removeprefix("data: ").strip()
                    if not data or data == "[DONE]":
                        continue
                    try:
                        obj = json.loads(data)
                        if obj.get("type") == "content_block_delta":
                            text = obj["delta"].get("text", "")
                            if text:
                                yield text
                    except (json.JSONDecodeError, KeyError):
                        continue


from schemas import NODE_ID_PATTERN as _NODE_ID_RE  # one id rule for all entry points


def _to_float(value) -> float | None:
    if value is None:
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def _log_ingest_outcome(fut) -> None:
    """Observe an MQTT-dispatched ingest future so failures are never silent."""
    exc = fut.exception()
    if exc is not None:
        _log.error("mqtt_ingest_failed error=%s", exc)


class AlertEngine:
    """Background task that raises/clears alerts for offline nodes and
    out-of-range telemetry, emitting each transition once.

    Alerts are written to the ``stream:alerts`` Redis stream and pushed onto the
    live SSE feed so the dashboard updates without polling. Active-alert state is
    tracked in a Redis set so a condition that persists across scans does not
    re-fire every interval — only the raised→cleared transitions emit.
    """

    def __init__(self, settings: Settings, cache: "Cache"):
        self._settings = settings
        self._cache = cache
        self._task: asyncio.Task | None = None
        self._stop = asyncio.Event()

    def start(self) -> None:
        self._task = asyncio.create_task(self._run())
        _log.info("alert_engine_started interval=%ss", self._settings.alert_scan_interval)

    async def stop(self) -> None:
        self._stop.set()
        if self._task:
            self._task.cancel()
            try:
                await self._task
            except asyncio.CancelledError:
                pass

    async def _run(self) -> None:
        interval = self._settings.alert_scan_interval
        while not self._stop.is_set():
            try:
                await self._scan()
            except Exception as exc:  # pragma: no cover - resilience
                _log.error("alert_scan_failed error=%s", exc)
            try:
                await asyncio.wait_for(self._stop.wait(), timeout=interval)
            except asyncio.TimeoutError:
                pass

    async def _scan(self) -> None:
        s = self._settings
        now = int(time.time())
        # One SMEMBERS per scan instead of one SISMEMBER per node per kind —
        # at N nodes that collapses 4N round-trips into 1.
        active = await self._cache.get_active_alerts()
        for node in await self._cache.list_nodes():
            last_seen = await self._cache.get_last_seen(node)
            offline = last_seen is not None and (now - last_seen) > s.node_offline_seconds
            await self._transition(
                node, "offline", offline,
                f"Node offline > {s.node_offline_seconds}s", "warning", active,
            )

            tele = await self._cache.get_all_telemetry(node)
            moisture = _to_float(tele.get("moisture"))
            await self._transition(
                node, "dry", moisture is not None and moisture < s.moisture_low_threshold,
                f"Soil moisture low ({moisture}% VWC)", "warning", active,
            )
            battery = _to_float(tele.get("battery_pct"))
            await self._transition(
                node, "battery", battery is not None and battery < s.battery_low_threshold,
                f"Battery low ({battery}%)", "warning", active,
            )

            diag = await self._cache.get_camera_diagnostics(node)
            issue = diag.get("issue", "None")
            conf = _to_float(diag.get("confidence")) or 0.0
            diseased = (
                issue not in (None, "None")
                and "healthy" not in str(issue).lower()
                and conf >= s.disease_confidence_threshold
            )
            await self._transition(
                node, "disease", diseased,
                f"Disease detected: {issue} ({conf:.0%})", "critical", active,
            )

    async def _transition(
        self, node: str, kind: str, active_now: bool, message: str, severity: str,
        active: set[str],
    ) -> None:
        member = f"{node}:{kind}"
        was_active = member in active
        if active_now and not was_active:
            await self._emit(node, kind, severity, message, "raised")
            await self._cache.set_alert_active(node, kind, True)
            active.add(member)
        elif not active_now and was_active:
            await self._emit(node, kind, severity, f"Recovered: {kind}", "cleared")
            await self._cache.set_alert_active(node, kind, False)
            active.discard(member)

    async def _emit(
        self, node: str, kind: str, severity: str, message: str, state: str
    ) -> None:
        alert = {
            "node_id": node,
            "kind": kind,
            "severity": severity if state == "raised" else "info",
            "state": state,
            "message": message,
            "timestamp": utc_now_iso(),
        }
        await self._cache.add_alert(alert)
        # Live push to the dashboard via the typed SSE event stream.
        await self._cache.emit_event("alert", node, alert)
        _log.info("alert_%s node=%s kind=%s", state, node, kind)
        await self._maybe_webhook(alert)

    async def _maybe_webhook(self, alert: dict) -> None:
        url = self._settings.alert_webhook_url
        if not url:
            return
        try:
            async with httpx.AsyncClient(timeout=10.0) as client:
                await client.post(url, json=alert)
        except Exception as exc:  # pragma: no cover - external
            _log.warning("alert_webhook_failed error=%s", exc)


class MqttPublisher:
    """Outbound MQTT for actuator commands (``pms/command/{zone}``).

    Separate from the subscriber. Safe to use with no hardware listening — the
    publish simply has no subscriber (the ControlEngine's Redis state is the
    source of truth for the virtual actuator). Non-fatal if the broker is down.
    """

    def __init__(self, settings: Settings):
        self._client = mqtt.Client(client_id="pms-api-publisher", clean_session=True)
        if settings.mqtt_username:
            self._client.username_pw_set(settings.mqtt_username, settings.mqtt_password)
        if settings.mqtt_ca_cert:
            import ssl
            self._client.tls_set(
                ca_certs=settings.mqtt_ca_cert, tls_version=ssl.PROTOCOL_TLS_CLIENT
            )
        self._host = settings.mqtt_host
        self._port = settings.mqtt_port
        self.connected = False
        self._client.on_connect = self._on_connect
        self._client.on_disconnect = self._on_disconnect

    def _on_connect(self, client, userdata, flags, rc):  # noqa: ARG002
        self.connected = rc == 0
        if rc == 0:
            _log.info("mqtt_publisher_connected host=%s port=%s", self._host, self._port)
        else:
            _log.error("mqtt_publisher_connect_failed rc=%s", rc)

    def _on_disconnect(self, client, userdata, rc):  # noqa: ARG002
        self.connected = False
        _log.warning("mqtt_publisher_disconnected rc=%s", rc)

    def start(self) -> None:
        try:
            # connect_async + loop_start: paho keeps retrying in the background,
            # so a broker that is down at API boot (or dies later) is picked up
            # again automatically and `connected` tracks reality via callbacks.
            self._client.connect_async(self._host, self._port, keepalive=60)
            self._client.loop_start()
        except Exception as exc:
            _log.warning("mqtt_publisher_unavailable error=%s", exc)

    def publish_command(self, zone: str, payload: dict) -> None:
        topic = f"pms/command/{zone}"
        try:
            self._client.publish(topic, json.dumps(payload))
        except Exception as exc:  # pragma: no cover - best effort
            _log.warning("mqtt_command_publish_failed zone=%s error=%s", zone, exc)

    def stop(self) -> None:
        try:
            self._client.loop_stop()
            self._client.disconnect()
        except Exception:
            pass


class ControlEngine:
    """Closed-loop irrigation control with safety interlocks.

    A zone == a soil node. On each scan the engine reads the zone's latest
    moisture and decides whether to irrigate. The actuator is **virtual**: the
    authoritative ON/OFF + runtime state lives in Redis and advances on timers
    regardless of whether a physical controller node is connected, so the whole
    loop is demoable without a pump. When a controller is flashed it subscribes
    to ``pms/command/{zone}`` and the published commands drive a real relay.

    Safety is non-negotiable. Actuation is blocked by: emergency stop, advisory
    mode (log only), per-zone cooldown, single-run max duration, daily runtime
    cap, and a sensor-sanity gate (no actuation on stale/implausible readings).
    Every decision and actuation is written to the ``logs:automation`` audit
    stream.
    """

    def __init__(self, settings: Settings, cache: "Cache", publisher: "MqttPublisher | None"):
        self._settings = settings
        self._cache = cache
        self._pub = publisher
        self._task: asyncio.Task | None = None
        self._stop = asyncio.Event()

    # ── lifecycle ─────────────────────────────────────────────────────────────
    def start(self) -> None:
        self._task = asyncio.create_task(self._run())
        _log.info("control_engine_started interval=%ss", self._settings.control_scan_interval)

    async def stop(self) -> None:
        self._stop.set()
        if self._task:
            self._task.cancel()
            try:
                await self._task
            except asyncio.CancelledError:
                pass

    async def _run(self) -> None:
        interval = self._settings.control_scan_interval
        while not self._stop.is_set():
            try:
                await self.scan()
            except Exception as exc:  # pragma: no cover - resilience
                _log.error("control_scan_failed error=%s", exc)
            try:
                await asyncio.wait_for(self._stop.wait(), timeout=interval)
            except asyncio.TimeoutError:
                pass

    # ── config ────────────────────────────────────────────────────────────────
    async def effective_config(self) -> dict:
        """Settings defaults overlaid with operator overrides (Redis)."""
        s = self._settings
        cfg: dict = {
            "mode": s.automation_mode_default,
            "emergency_stop": False,
            "moisture_setpoint": s.irrigation_moisture_setpoint,
            "moisture_target": s.irrigation_moisture_target,
            "max_run_seconds": s.actuator_max_run_seconds,
            "cooldown_seconds": s.actuator_cooldown_seconds,
            "daily_cap_seconds": s.actuator_daily_cap_seconds,
        }
        stored = await self._cache.get_automation_config()
        if stored.get("mode") in ("advisory", "auto"):
            cfg["mode"] = stored["mode"]
        if "emergency_stop" in stored:
            cfg["emergency_stop"] = stored["emergency_stop"] in ("1", "true", "True")
        for k in ("moisture_setpoint", "moisture_target"):
            if k in stored:
                v = _to_float(stored[k])
                if v is not None:  # 0 is a legal operator override — `or` isn't
                    cfg[k] = v
        for k in ("max_run_seconds", "cooldown_seconds", "daily_cap_seconds"):
            if k in stored:
                v = _to_float(stored[k])
                if v is not None:
                    cfg[k] = int(v)
        return cfg

    # ── scan ──────────────────────────────────────────────────────────────────
    async def scan(self) -> None:
        cfg = await self.effective_config()
        now = int(time.time())
        today = time.strftime("%Y-%m-%d", time.gmtime(now))
        for node in await self._cache.list_nodes():
            tele = await self._cache.get_all_telemetry(node)
            if "moisture" not in tele:
                continue  # only soil/irrigation zones are controllable
            await self._evaluate(node, tele, cfg, now, today)

    async def _evaluate(self, zone, tele, cfg, now, today) -> None:
        state = await self._cache.get_zone_state(zone)
        on = state.get("on") == "1"
        since = int(_to_float(state.get("since")) or 0)
        run_today = int(_to_float(state.get("run_today")) or 0)
        day = state.get("day", today)
        last_off = int(_to_float(state.get("last_off")) or 0)
        advised = state.get("advised") == "1"
        if day != today:  # daily reset
            run_today = 0
            day = today

        moisture = _to_float(tele.get("moisture"))
        last_seen = await self._cache.get_last_seen(zone)
        sensor_fresh = (
            moisture is not None
            and last_seen is not None
            and (now - last_seen) <= self._settings.sensor_sanity_max_age_seconds
        )

        if on:
            elapsed = now - since
            run_live = run_today + elapsed
            stop_reason = None
            if cfg["emergency_stop"]:
                stop_reason = "emergency_stop"
            elif elapsed >= cfg["max_run_seconds"]:
                stop_reason = "max_run_reached"
            elif moisture is not None and moisture >= cfg["moisture_target"]:
                stop_reason = "target_reached"
            elif run_live >= cfg["daily_cap_seconds"]:
                stop_reason = "daily_cap_reached"
            if stop_reason:
                await self._actuate(
                    zone, on=False, now=now, run_today=run_today + elapsed,
                    day=day, last_off=now, reason=stop_reason, cfg=cfg,
                )
            return

        # currently OFF — consider raising/clearing an advisory and acting.
        if moisture is None or moisture >= cfg["moisture_setpoint"]:
            # Soil is fine (or unknown): clear any standing advisory.
            if advised:
                await self._cache.set_zone_state(zone, {"advised": 0})
            return

        # moisture < setpoint → wants water. Run safety interlocks.
        block = None
        if cfg["emergency_stop"]:
            block = "emergency_stop"
        elif not sensor_fresh:
            block = "sensor_stale"
        elif (now - last_off) < cfg["cooldown_seconds"]:
            block = "cooldown"
        elif run_today >= cfg["daily_cap_seconds"]:
            block = "daily_cap"

        if block:
            # Record the suppressed decision once per dry episode (no per-scan spam).
            if not advised:
                await self._cache.log_automation_decision(
                    zone, "BLOCKED",
                    {"moisture": moisture, "reason": block, "mode": cfg["mode"]},
                )
                await self._cache.set_zone_state(zone, {"advised": 1, "day": day,
                                                        "run_today": run_today})
            return

        if cfg["mode"] == "auto":
            await self._actuate(
                zone, on=True, now=now, run_today=run_today, day=day,
                last_off=last_off, reason="moisture_below_setpoint", cfg=cfg,
            )
        else:  # advisory: log a suggestion once, do NOT actuate
            if not advised:
                await self._cache.log_automation_decision(
                    zone, "SUGGESTION",
                    {"moisture": moisture, "setpoint": cfg["moisture_setpoint"],
                     "message": "Soil below setpoint — irrigation suggested."},
                )
                await self._cache.set_zone_state(zone, {"advised": 1, "day": day,
                                                        "run_today": run_today})

    async def _actuate(self, zone, on, now, run_today, day, last_off, reason, cfg) -> None:
        # Hardware means a controller node recently heartbeated on
        # pms/status/{zone} — the API's own broker connection proves nothing
        # about a relay existing (Mosquitto is always up in Docker).
        alive = await self._cache.controller_alive(
            zone, self._settings.sensor_sanity_max_age_seconds
        )
        bound = "hardware" if alive else "virtual"
        new_state = {
            "on": 1 if on else 0,
            "since": now if on else 0,
            "run_today": run_today,
            "day": day,
            "last_off": last_off,
            "reason": reason,
            "bound": bound,
            "mode": cfg["mode"],
            "advised": 0,
        }
        await self._cache.set_zone_state(zone, new_state)
        # Best-effort command to a (possibly absent) controller node.
        if self._pub:
            self._pub.publish_command(zone, {
                "action": "on" if on else "off",
                "zone": zone,
                "reason": reason,
                "max_run_seconds": cfg["max_run_seconds"],
                "ts": now,
            })
        await self._cache.log_automation_decision(
            zone, "ACTUATE_ON" if on else "ACTUATE_OFF",
            {"reason": reason, "bound": bound, "mode": cfg["mode"]},
        )
        # Live push so the dashboard reflects actuator state immediately.
        await self._cache.emit_event("actuator", zone, {
            "on": bool(on), "reason": reason, "bound": bound,
            "mode": cfg["mode"], "since": now if on else 0,
        })
        _log.info("actuate zone=%s on=%s reason=%s bound=%s", zone, on, reason, bound)

    async def manual_command(self, zone: str, action: str) -> dict:
        """Operator manual override (admin-gated). OFF is always allowed (safety).
        ON respects emergency stop + daily cap but bypasses the cooldown/setpoint
        (the operator is asserting intent). Auto-off still applies via the scan.
        """
        cfg = await self.effective_config()
        now = int(time.time())
        today = time.strftime("%Y-%m-%d", time.gmtime(now))
        state = await self._cache.get_zone_state(zone)
        run_today = int(_to_float(state.get("run_today")) or 0)
        day = state.get("day", today)
        if day != today:
            run_today = 0
        if action == "off":
            since = int(_to_float(state.get("since")) or now)
            elapsed = now - since if state.get("on") == "1" else 0
            await self._actuate(zone, on=False, now=now, run_today=run_today + elapsed,
                                day=today, last_off=now, reason="manual_off", cfg=cfg)
            return {"zone": zone, "on": False, "reason": "manual_off"}
        # action == "on"
        if cfg["emergency_stop"]:
            return {"zone": zone, "on": False, "blocked": "emergency_stop"}
        if run_today >= cfg["daily_cap_seconds"]:
            return {"zone": zone, "on": False, "blocked": "daily_cap"}
        await self._actuate(zone, on=True, now=now, run_today=run_today, day=today,
                            last_off=int(_to_float(state.get("last_off")) or 0),
                            reason="manual_on", cfg=cfg)
        return {"zone": zone, "on": True, "reason": "manual_on"}


class MQTTSubscriber:
    """Background MQTT subscriber that bridges soil-node telemetry into Redis/InfluxDB.

    Paho-mqtt runs its network loop in a daemon thread. Messages are dispatched
    back to the main asyncio event loop via ``run_coroutine_threadsafe`` so that
    async Redis/InfluxDB calls work normally.

    The subscriber is non-critical: if Mosquitto is unavailable (unit tests,
    dev without the broker running) it logs a warning and the API continues
    serving HTTP telemetry without interruption.
    """

    TOPIC = "pms/telemetry/#"
    STATUS_TOPIC = "pms/status/#"

    def __init__(
        self,
        settings: Settings,
        cache: "Cache",
        tsdb: "TimeSeriesDB | None",
        loop: asyncio.AbstractEventLoop,
    ):
        self._cache = cache
        self._tsdb = tsdb
        self._loop = loop
        self._client = mqtt.Client(client_id="pms-api-subscriber", clean_session=True)

        if settings.mqtt_username:
            self._client.username_pw_set(settings.mqtt_username, settings.mqtt_password)

        if settings.mqtt_ca_cert:
            import ssl
            self._client.tls_set(ca_certs=settings.mqtt_ca_cert,
                                 tls_version=ssl.PROTOCOL_TLS_CLIENT)

        self._client.on_connect = self._on_connect
        self._client.on_message = self._on_message
        self._host = settings.mqtt_host
        self._port = settings.mqtt_port

    # ── paho callbacks (run in paho's thread) ────────────────────────────────

    def _on_connect(self, client, userdata, flags, rc):  # noqa: ARG002
        if rc == 0:
            _log.info("mqtt_subscriber_connected host=%s port=%s", self._host, self._port)
            client.subscribe(self.TOPIC)
            client.subscribe(self.STATUS_TOPIC)
        else:
            _log.error("mqtt_subscriber_connect_failed rc=%s", rc)

    def _on_message(self, client, userdata, msg):  # noqa: ARG002
        try:
            payload = json.loads(msg.payload.decode("utf-8"))
        except (json.JSONDecodeError, UnicodeDecodeError):
            _log.warning("mqtt_invalid_payload topic=%s", msg.topic)
            return
        # Controller heartbeat (pms/status/{node_id}) — proof a relay exists.
        # Retained status would fake hardware presence, so it is ignored.
        if msg.topic.startswith("pms/status/"):
            if not msg.retain:
                fut = asyncio.run_coroutine_threadsafe(
                    self._ingest_status(payload), self._loop
                )
                fut.add_done_callback(_log_ingest_outcome)
            return
        # Dispatch to the asyncio event loop — safe to call from any thread.
        # The done-callback observes the future: without it an exception inside
        # _ingest (e.g. Redis down) vanishes silently and telemetry just stops.
        fut = asyncio.run_coroutine_threadsafe(
            self._ingest(payload, retained=bool(msg.retain)), self._loop
        )
        fut.add_done_callback(_log_ingest_outcome)

    async def _ingest_status(self, payload: dict) -> None:
        node_id = str(payload.get("node_id", "")).strip()
        if not node_id or not _NODE_ID_RE.match(node_id):
            _log.warning("mqtt_bad_status_node_id value=%r", node_id)
            return
        await self._cache.set_controller_seen(node_id)

    # ── async ingest (runs on the main event loop) ────────────────────────────

    async def _ingest(self, payload: dict, retained: bool = False) -> None:
        node_id = str(payload.get("node_id", "")).strip()
        if not node_id or not _NODE_ID_RE.match(node_id):
            _log.warning("mqtt_bad_node_id value=%r", node_id)
            return

        # First sighting? Persist the pairing so the dashboard card never drops
        # off even if the device goes dark for a while. Write-once: never
        # overwrites a profile set at pairing, never touches last_seen — a
        # retained message redelivered by the broker must not fake liveness.
        await self._cache.note_node_seen(node_id, default_profile={"kind": "soil"})

        # Wake-up "hello" message: a soil node announces itself on boot before
        # the first reading. No sensor fields present → just refresh last_seen.
        if payload.get("hello") is True:
            if retained:
                return
            await self._cache.touch_node(node_id)
            _log.info("mqtt_node_hello node_id=%s", node_id)
            # Tell SSE consumers the card should appear immediately.
            await self._cache.emit_event("online", node_id, {})
            return

        # Silently skip sentinel readings where sensor reported an error
        if not payload.get("sensor_ok", True):
            _log.info("mqtt_sensor_offline node_id=%s", node_id)
            if not retained:
                await self._cache.touch_node(node_id)
            return

        fields: dict[str, float] = {}

        async def _store(cache_key: str, payload_key: str,
                         lo: float | None = None, hi: float | None = None) -> None:
            raw = payload.get(payload_key)
            if raw is None:
                return
            try:
                v = float(raw)
            except (TypeError, ValueError):
                return
            if lo is not None and v < lo:
                return
            if hi is not None and v > hi:
                return
            await self._cache.set_telemetry(node_id, cache_key, v)
            fields[cache_key] = v

        await _store("moisture",    "moisture",    0.0,   100.0)
        await _store("temperature", "temperature", -50.0,  80.0)
        await _store("ec",          "ec",          0.0,   None)
        await _store("battery_pct", "battery_pct", 0.0,   100.0)

        # Firmware-diagnostic fields. Cached (so the dashboard can surface them)
        # but not written to InfluxDB — these are not metrics, they are device
        # health flags that change only on reboot.
        reset_reason = str(payload.get("reset_reason", "")).strip()[:32]
        if reset_reason:
            await self._cache.set_telemetry(node_id, "reset_reason", reset_reason)
        free_heap = payload.get("free_heap")
        if isinstance(free_heap, (int, float)) and free_heap >= 0:
            await self._cache.set_telemetry(node_id, "free_heap", int(free_heap))

        if not fields:
            return

        if retained:
            # Values are cached above for display (last-known reading after a
            # backend restart) but a retained message proves nothing about the
            # node being alive NOW — no last_seen refresh, no live SSE event.
            return

        await self._cache.touch_node(node_id)
        await self._cache.emit_event("telemetry", node_id, fields)

        if self._tsdb is not None:
            try:
                await asyncio.to_thread(
                    self._tsdb.write_telemetry, node_id, fields
                )
            except Exception as exc:
                _log.error("mqtt_influxdb_write_failed node_id=%s error=%s", node_id, exc)

        _log.info("mqtt_telemetry_ingested node_id=%s fields=%s", node_id, list(fields.keys()))

    # ── lifecycle ─────────────────────────────────────────────────────────────

    def start(self) -> None:
        try:
            self._client.connect(self._host, self._port, keepalive=60)
            self._client.loop_start()          # starts paho's background thread
            _log.info("mqtt_subscriber_started host=%s port=%s topic=%s",
                      self._host, self._port, self.TOPIC)
        except Exception as exc:
            _log.warning("mqtt_subscriber_unavailable error=%s — HTTP telemetry still works", exc)

    def stop(self) -> None:
        try:
            self._client.loop_stop()
            self._client.disconnect()
        except Exception:
            pass
