"""Unit tests for service-layer serialization contracts."""
import time
from unittest.mock import AsyncMock, MagicMock

import pytest

from config import Settings
from services import AlertEngine, Cache, ControlEngine, MQTTSubscriber


def _cfg(**over):
    base = {
        "mode": "auto",
        "emergency_stop": False,
        "moisture_setpoint": 30.0,
        "moisture_target": 55.0,
        "max_run_seconds": 300,
        "cooldown_seconds": 300,
        "daily_cap_seconds": 3600,
    }
    base.update(over)
    return base


def _control_cache(zone_state=None, last_seen=None, controller_alive=False):
    cache = AsyncMock()
    cache.get_zone_state = AsyncMock(return_value=dict(zone_state or {}))
    cache.get_last_seen = AsyncMock(
        return_value=last_seen if last_seen is not None else int(time.time())
    )
    cache.set_zone_state = AsyncMock()
    cache.log_automation_decision = AsyncMock()
    cache.publish_telemetry_stream = AsyncMock()
    cache.controller_alive = AsyncMock(return_value=controller_alive)
    return cache


def _last_state(cache):
    """The fields dict from the most recent set_zone_state call."""
    return cache.set_zone_state.await_args.args[1]


def _last_decision(cache):
    return cache.log_automation_decision.await_args.args[1]


_NOW = int(time.time())
_TODAY = time.strftime("%Y-%m-%d", time.gmtime(_NOW))


@pytest.mark.anyio
async def test_log_automation_decision_serializes_context_to_scalars():
    """Regression: Redis stream (XADD) fields must be flat scalars. Passing a
    nested dict raises redis.exceptions.DataError at runtime, which previously
    crashed /analyze on every high-confidence detection."""
    cache = Cache(Settings())
    fake_redis = AsyncMock()
    cache._r = fake_redis  # inject a fake text-mode client

    await cache.log_automation_decision(
        "cam-1", "SUGGESTION", {"issue": "Tomato_Late_blight", "confidence": 0.9}
    )

    fake_redis.xadd.assert_awaited_once()
    args, _ = fake_redis.xadd.call_args
    stream_name, entry = args[0], args[1]
    assert stream_name == "logs:automation"
    for key, value in entry.items():
        assert isinstance(value, (str, int, float, bytes)), (
            f"stream field {key!r} is non-scalar: {value!r}"
        )


@pytest.mark.anyio
async def test_emit_event_stream_fields_are_scalars():
    """Redis stream (XADD) fields must be flat scalars — nested dicts raise
    redis.exceptions.DataError at runtime."""
    cache = Cache(Settings())
    fake_redis = AsyncMock()
    cache._r = fake_redis

    await cache.emit_event("telemetry", "soil-1", {"moisture": 42})

    args, _ = fake_redis.xadd.call_args
    entry = args[1]
    for key, value in entry.items():
        assert isinstance(value, (str, int, float, bytes)), (
            f"stream field {key!r} is non-scalar: {value!r}"
        )


@pytest.mark.anyio
async def test_emit_event_wraps_typed_envelope():
    """Every SSE event goes through one door with a type discriminator, so the
    client dispatches on data.type instead of sniffing payload keys."""
    import json as _json

    cache = Cache(Settings())
    fake_redis = AsyncMock()
    cache._r = fake_redis

    await cache.emit_event("telemetry", "soil-a", {"moisture": 41.0})

    fake_redis.xadd.assert_awaited_once()
    args, _ = fake_redis.xadd.call_args
    assert args[0] == "stream:telemetry"
    entry = args[1]
    assert entry["node_id"] == "soil-a"
    assert _json.loads(entry["data"]) == {
        "type": "telemetry",
        "payload": {"moisture": 41.0},
    }


@pytest.mark.anyio
async def test_emit_event_rejects_unknown_type():
    cache = Cache(Settings())
    cache._r = AsyncMock()

    with pytest.raises(ValueError, match="unknown event type"):
        await cache.emit_event("mystery", "soil-a", {})


@pytest.mark.anyio
async def test_alert_engine_raises_once_then_clears():
    """An offline condition fires exactly one 'raised' alert while it persists,
    and one 'cleared' alert when it recovers — no per-scan spam."""
    cache = AsyncMock()
    cache.list_nodes = AsyncMock(return_value=["soil-1"])
    cache.get_last_seen = AsyncMock(return_value=0)  # epoch 0 -> very old -> offline
    cache.get_all_telemetry = AsyncMock(return_value={})
    cache.get_camera_diagnostics = AsyncMock(
        return_value={"issue": "None", "confidence": 0.0}
    )
    cache.add_alert = AsyncMock()
    cache.publish_telemetry_stream = AsyncMock()

    # Track active-alert state in-memory so de-dup logic is exercised.
    active: set[str] = set()

    async def _is_active(node, kind):
        return f"{node}:{kind}" in active

    async def _set_active(node, kind, on):
        active.add(f"{node}:{kind}") if on else active.discard(f"{node}:{kind}")

    cache.is_alert_active = _is_active
    cache.set_alert_active = _set_active

    engine = AlertEngine(Settings(), cache)

    await engine._scan()
    assert cache.add_alert.await_count == 1  # offline raised once

    await engine._scan()
    assert cache.add_alert.await_count == 1  # still offline -> de-duped, no new alert

    cache.get_last_seen = AsyncMock(return_value=int(time.time()))  # back online
    await engine._scan()
    assert cache.add_alert.await_count == 2  # cleared emitted once


# ── MQTT ingest: retained messages must not fake liveness ────────────────────

def _subscriber(mock_cache):
    return MQTTSubscriber(Settings(), mock_cache, None, None)


def _ingest_cache():
    cache = AsyncMock()
    cache.note_node_seen = AsyncMock()
    cache.touch_node = AsyncMock()
    cache.set_telemetry = AsyncMock()
    cache.emit_event = AsyncMock()
    return cache


@pytest.mark.anyio
async def test_retained_message_does_not_refresh_last_seen():
    """A broker-redelivered retained reading may be days old: cache the value
    for display, but never refresh liveness or emit a live SSE event — the
    ControlEngine's stale-sensor interlock depends on honest last_seen."""
    cache = _ingest_cache()
    sub = _subscriber(cache)

    await sub._ingest({"node_id": "soil-a", "moisture": 40.0}, retained=True)

    cache.set_telemetry.assert_awaited()          # value still cached
    cache.touch_node.assert_not_awaited()         # liveness untouched
    cache.emit_event.assert_not_awaited()         # no fake-live SSE


@pytest.mark.anyio
async def test_live_message_refreshes_last_seen():
    cache = _ingest_cache()
    sub = _subscriber(cache)

    await sub._ingest({"node_id": "soil-a", "moisture": 40.0}, retained=False)

    cache.touch_node.assert_awaited()
    cache.emit_event.assert_awaited_with("telemetry", "soil-a", {"moisture": 40.0})


@pytest.mark.anyio
async def test_ingest_does_not_overwrite_profile():
    """Ingest marks the node as seen with a write-once default profile; it must
    never call register_node, which overwrites kind and resets last_seen."""
    cache = _ingest_cache()
    sub = _subscriber(cache)

    await sub._ingest({"node_id": "cam-a", "moisture": 40.0})

    cache.note_node_seen.assert_awaited_with(
        "cam-a", default_profile={"kind": "soil"}
    )
    cache.register_node.assert_not_awaited()


@pytest.mark.anyio
async def test_effective_config_zero_setpoint_respected():
    """Regression: `_to_float(v) or default` treated a stored 0 as falsy and
    fell back to the 30.0 default — the pump kept firing after an operator
    explicitly disabled irrigation with setpoint 0."""
    cache = AsyncMock()
    cache.get_automation_config = AsyncMock(
        return_value={"moisture_setpoint": "0"}
    )
    engine = ControlEngine(Settings(), cache, None)

    cfg = await engine.effective_config()

    assert cfg["moisture_setpoint"] == 0.0  # NOT the 30.0 default


# ── ControlEngine safety interlocks ──────────────────────────────────────────

@pytest.mark.anyio
async def test_control_auto_actuates_when_dry():
    cache = _control_cache()
    pub = MagicMock()
    pub.connected = True
    engine = ControlEngine(Settings(), cache, pub)

    await engine._evaluate("soil-1", {"moisture": "12"}, _cfg(), _NOW, _TODAY)

    assert _last_state(cache)["on"] == 1  # actuated ON
    pub.publish_command.assert_called_once()  # command published to the zone
    assert _last_decision(cache) == "ACTUATE_ON"


@pytest.mark.anyio
async def test_zone_bound_virtual_without_controller_ack():
    """No recent controller heartbeat -> the actuator is VIRTUAL, even if the
    API's own broker connection is up (that flag says nothing about a relay)."""
    cache = _control_cache(controller_alive=False)
    pub = MagicMock()
    pub.connected = True  # broker up — must NOT imply hardware
    engine = ControlEngine(Settings(), cache, pub)

    await engine._evaluate("soil-1", {"moisture": "12"}, _cfg(), _NOW, _TODAY)

    assert _last_state(cache)["bound"] == "virtual"


@pytest.mark.anyio
async def test_zone_bound_hardware_with_recent_controller_ack():
    cache = _control_cache(controller_alive=True)
    pub = MagicMock()
    pub.connected = True
    engine = ControlEngine(Settings(), cache, pub)

    await engine._evaluate("soil-1", {"moisture": "12"}, _cfg(), _NOW, _TODAY)

    assert _last_state(cache)["bound"] == "hardware"


def test_publisher_disconnect_flips_connected():
    from services import MqttPublisher

    pub = MqttPublisher(Settings())
    pub._on_connect(None, None, None, 0)
    assert pub.connected is True
    pub._on_disconnect(None, None, 1)
    assert pub.connected is False


@pytest.mark.anyio
async def test_control_advisory_logs_but_does_not_actuate():
    cache = _control_cache()
    engine = ControlEngine(Settings(), cache, None)

    await engine._evaluate("soil-1", {"moisture": "12"}, _cfg(mode="advisory"), _NOW, _TODAY)

    # Suggestion logged, but the zone is NOT switched on.
    assert _last_decision(cache) == "SUGGESTION"
    assert _last_state(cache).get("on") != 1


@pytest.mark.anyio
async def test_control_emergency_stop_blocks_actuation():
    cache = _control_cache()
    pub = MagicMock()
    pub.connected = True
    engine = ControlEngine(Settings(), cache, pub)

    await engine._evaluate(
        "soil-1", {"moisture": "12"}, _cfg(emergency_stop=True), _NOW, _TODAY
    )

    assert _last_decision(cache) == "BLOCKED"
    pub.publish_command.assert_not_called()
    assert _last_state(cache).get("on") != 1


@pytest.mark.anyio
async def test_control_cooldown_blocks_actuation():
    cache = _control_cache(zone_state={"last_off": _NOW - 100})  # 100s ago
    engine = ControlEngine(Settings(), cache, None)

    await engine._evaluate(
        "soil-1", {"moisture": "12"}, _cfg(cooldown_seconds=300), _NOW, _TODAY
    )

    assert _last_decision(cache) == "BLOCKED"
    assert _last_state(cache).get("on") != 1


@pytest.mark.anyio
async def test_control_stale_sensor_blocks_actuation():
    # last_seen far in the past -> sensor-sanity gate blocks actuation.
    cache = _control_cache(last_seen=_NOW - 100000)
    engine = ControlEngine(Settings(), cache, None)

    await engine._evaluate("soil-1", {"moisture": "12"}, _cfg(), _NOW, _TODAY)

    assert _last_decision(cache) == "BLOCKED"
    assert _last_state(cache).get("on") != 1


@pytest.mark.anyio
async def test_control_auto_off_at_max_run():
    # Zone running for 400s with a 300s cap -> must auto-off.
    cache = _control_cache(
        zone_state={"on": "1", "since": _NOW - 400, "run_today": "0", "day": _TODAY}
    )
    pub = MagicMock()
    pub.connected = True
    engine = ControlEngine(Settings(), cache, pub)

    await engine._evaluate(
        "soil-1", {"moisture": "12"}, _cfg(max_run_seconds=300), _NOW, _TODAY
    )

    assert _last_state(cache)["on"] == 0  # auto-off
    assert _last_decision(cache) == "ACTUATE_OFF"
