# Design: Fix Wave → UI Redesign → RPi Migration

Date: 2026-07-07
Status: Approved by user (direction: "evolved technical", imagery: "live data as imagery", execution order ① → ② → ③)

## Context

A full-source code review (8 finder angles, verified) produced 10 confirmed findings and a
cleanup tier. The system is a working monitoring + closed-loop automation platform
(ESP32 → MQTT/HTTP → FastAPI + Redis/InfluxDB/ONNX → Flutter web dashboard, 47 backend
tests green). The user wants maximum fixes and enhancements, a modern interactive UI
redesign (web + the same codebase packaged as the mobile app), and then migration of the
edge server from the Windows dev box to a Raspberry Pi.

Non-negotiable design rules carried forward: no floating colorful blurred bubbles, no
emojis, no round playful pill shapes. Dark technical "mission control" identity stays.

---

## Sub-project ① — Fix wave

### 1. Principal-scoped auth (fixes findings #1, #2, #6)

- `auth.py`: `require_auth` returns a `Principal` dataclass — `admin` or
  `device(node_id)` — instead of the raw token string. `_bearer` rejects empty
  credentials before any comparison.
- Node-scoped routes (`/telemetry` POST, `/node/{id}/upload-frame`, `/node/{id}/hello`)
  verify the path/payload `node_id` matches the device principal's node. Admin passes
  everywhere. Read routes (`/nodes`, `/stream`, `/alerts`, history) remain
  any-authenticated for now (dashboard uses admin; devices don't call them).
- `/node/{id}/hello` becomes idempotent: authenticated as the same device → return the
  existing token unchanged (no rotation). Rotation only when called with the admin token.
  This un-bricks the ESP32-CAM cold-boot problem with zero firmware change.
- `config.py`: startup validator — refuse to boot when `api_auth_token` is empty or the
  literal default, unless `environment == "development"`.
- Chat/LLM route requires admin (it spends money; devices have no reason to call it).

### 2. Control-loop truth (fixes findings #3, #4, #7)

- `ControlEngine.effective_config`: replace `_to_float(stored[k]) or cfg[k]` with an
  explicit `is not None` check so a stored `0` wins.
- `MQTTSubscriber`: pass `msg.retain` through to `_ingest`. Retained messages still
  cache field values (dashboard shows last-known) but do NOT refresh `last_seen` and do
  not emit SSE. `register_node` on the ingest path stops resetting `last_seen`; profile
  becomes write-once (`HSETNX` semantics) so a detection can't flip a soil node to
  "camera" or vice versa.
- `MqttPublisher`: `on_connect`/`on_disconnect` callbacks keep `.connected` truthful;
  use `connect_async` + `loop_start` so paho auto-reconnects.
- Hardware-vs-virtual binding becomes ack-based: a zone reports `bound: "hardware"`
  only when a controller node has heartbeated on `pms/status/{node_id}` within
  `sensor_sanity_max_age_seconds`; otherwise `virtual`. Redis key
  `controller:last_seen:{zone}` written by the subscriber on status messages.

### 3. Runtime health (fixes findings #5, #9, #10, #8)

- Inference calls in `/upload-frame` and `/analyze` wrapped in `asyncio.to_thread`;
  both routes rate-limited (slowapi), keyed on `X-Forwarded-For` when present.
- MQTT dispatch: attach a done-callback to the `run_coroutine_threadsafe` future that
  logs exceptions.
- Typed SSE envelope: every stream event becomes
  `{"type": "telemetry"|"alert"|"detection"|"actuator"|"online", "node_id": ..., "payload": {...}}`,
  emitted by ONE helper (`Cache.emit_event(type, node_id, payload)`). Client side: one
  dispatcher in the Dart layer switches on `type`; only `telemetry` events refresh
  `lastSeen`/`timestamp`. `mergeDelta` key-sniffing is deleted.
- `TelemetrySnapshot.copyWith()` added; `_refresh` in `dashboard_screen.dart` uses it
  (field list lives in one place; actuator fields survive refresh).

### 4. Cleanup tier (verified findings from reuse/simplification/efficiency angles)

- Delete `temp-plant-model-repo/` (83 MB dead clone), `ApiService.analyzeCamera` +
  `DiagnosticSnapshot`, `Cache.get_telemetry`, `Cache.list_zones`.
- Extract shared helpers: `utc_now_iso()` (3 copies), `TreatmentDB.treatments_for(label)`
  (3 divergent copies), `_json_body(request)` (3 copies), `NodeId` annotated type
  (4 regex copies), `services._to_float` reused by routes.
- `api_service.dart`: private `_getJson`/`_postJson` + one auth-header builder replace
  10+ hand-rolled request blocks.
- Canonicalize `temperature` at the ingest boundary — the cache stores `temperature`,
  the `temp` key dies everywhere (chat prompt updated; one-time read fallback kept for
  old cached values).
- Bulk `GET /nodes/telemetry` endpoint (one pipelined Redis batch) replaces the N+1
  per-node HTTP refresh; dashboard `_refresh` uses it.
- Redis pipelining in `AlertEngine._scan` / `ControlEngine.scan` (one `SMEMBERS` of
  active alerts per scan; shared keyspace scan).
- Chat panel becomes its own StatefulWidget so token streaming stops rebuilding the
  card grid; card list held per-node so SSE deltas rebuild only the affected card.
- Soil firmware: remove the fixed 500 ms `mqtt_client.loop()` drain spin (QoS0 needs
  one loop + disconnect). Keep `retain=true` (backend now handles it correctly).
- Consolidate duplicated UI chrome (3 command-button copies, duplicated `_toast`,
  9 inline color literals) into the design system — executed as the first step of ②.

### Testing ①

All 47 existing tests stay green (updated where contracts changed: SSE envelope,
hello idempotence). New tests: device-token scoping (device A cannot post as B, cannot
hello B), hello idempotence, retained-message ingest (values cached, `last_seen`
untouched), falsy-zero setpoint override, publisher reconnect state, envelope shapes.

---

## Sub-project ② — UI redesign: "evolved technical"

One Flutter codebase; every improvement applies to web kiosk AND the Android app.

### Design system first

- `app_theme.dart` grows into a token layer: full color set (including `insetFill`,
  `bgLift` used everywhere instead of inline literals), spacing, type scale, and a
  `AppMotion` set (durations + curves: fast 150 ms, base 250 ms, drawIn 600 ms,
  `Curves.easeOutCubic` family).
- `widgets/` consolidates shared chrome: one `CommandButton`, one toast helper, chips,
  section headers. Screens stop owning copies.

### Motion layer (all code-drawn, no new heavy dependencies)

- Animated ring/arc gauge for moisture (CustomPainter, sweep-in on load, tween on change).
- Live pulse dot per card driven by real SSE ticks (existing `updateTick`).
- Value tick animations (TweenAnimationBuilder) on numeric readings.
- Staggered card entrance on grid load; card hover/press elevation on web.
- Hero transitions card → node detail (camera frame / gauge as the shared element).
- fl_chart draw-in animation + gradient area fills on history charts.
- Flowing-dash line animation on zones with the actuator ON.
- Scanline sweep overlay on a camera frame while analysis is in flight.
- Alerts bar slide-in/out; smooth stale-dimming transition.

### Imagery = live data

- Latest camera frame as dimmed card background (gradient scrim for text contrast) and
  as a full-bleed hero on the detail screen; detection state renders as an edge glow +
  animated corner brackets with confidence.
- Node-kind glyphs (soil probe, camera, zone controller) drawn as CustomPainter
  line-art — zero asset bytes — used on cards and empty states.
- Login screen: subtle animated grid/topographic backdrop (code-drawn).

### Mobile-specific (same codebase, LayoutBuilder-switched)

- Bottom navigation bar under 700 px: Grid / Alerts / Automation / Agronomist.
- Pull-to-refresh on the grid; haptic feedback on commands; larger touch targets;
  full-screen capture flow for "Capture Leaf".

### Testing ②

`flutter analyze` clean; widget tests for the dispatcher and copyWith merge; manual
visual verification on web + one Android device; web bundle rebuilt through the
existing no-cache nginx config.

---

## Sub-project ③ — RPi migration

Executed only after ① lands (never deploy the known auth holes). Deliverable: a
step-by-step guide + assisted run.

1. Flash Raspberry Pi OS 64-bit (Bookworm), enable SSH.
2. Copy/clone the project to the Pi (`git init` + push, or direct copy; excludes
   `.venv`, `build/`, deleted `temp-plant-model-repo`).
3. Run `deploy/pi-setup.sh` (installs Docker, sets up the systemd unit, does NOT
   auto-start).
4. Fill `edge-server/.env` on the Pi — now enforced by the ① startup check
   (`API_AUTH_TOKEN`, InfluxDB creds, Gemini key).
5. `DASHBOARD_DOCKERFILE=Dockerfile.pi` for the ARM64 dashboard build (systemd unit
   already carries the override).
6. Start the stack, verify health endpoints, open firewall 8000/1883 if ufw present.
7. Re-flash both ESPs' `secrets.h` with the Pi's LAN IP (MQTT_HOST + API_BASE_URL);
   confirm cards go live on the Pi-served dashboard.
8. Optional: kiosk mode via `deploy/kiosk-setup.sh`.
9. Verification checklist: `/api/v1/health`, live soil card, camera detection cycle,
   automation advisory log entry, chat streaming.

Known risks: Docker-on-Pi first-boot cgroup settings (handled in pi-setup.sh), ARM64
image build time (~10–20 min for the Flutter web build on a Pi 5), and the user's
earlier Pi hardware issues (assist interactively).

---

## Execution order

① fix wave (backend → firmware → dashboard model/service) → ② design system → motion →
imagery → mobile nav → ③ RPi. Each sub-project verified before the next starts.
