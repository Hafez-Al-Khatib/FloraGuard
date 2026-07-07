# MQTT Topic Schema

Broker: Mosquitto running inside Docker (`pms-mosquitto` / `pms-mosquitto-dev`).  
All topics are prefixed with `pms/`.

---

## `pms/telemetry/{node_id}` — soil sensor telemetry

Published by: **Soil Node (Type A)** ESP32-S3 firmware  
Subscribed by: **FastAPI** `MQTTSubscriber` (writes to Redis cache + InfluxDB)

Hardware: HW-103 / HW-080 **analog capacitive** soil moisture sensors.  
Each sensor connects VCC→3.3V, GND→GND, AOUT→ADC1 GPIO.  
No RS485, no Modbus — purely analog `analogRead()`.

### Payload (JSON)

```json
{
  "node_id":     "soil-zone-a",
  "seq":         42,
  "sensor_ok":   true,
  "moisture":    58.4,
  "battery_pct": 87,
  "reset_reason": "deepsleep",
  "free_heap":   214320
}
```

| Field | Type | Unit | Notes |
|---|---|---|---|
| `node_id` | string | — | Must match `[a-zA-Z0-9_-]{1,64}` |
| `seq` | uint32 | — | RTC boot counter |
| `sensor_ok` | bool | — | Always `true` for analog sensors (no bus error possible) |
| `moisture` | float | % VWC | 0–100, mapped from ADC via dry/wet calibration |
| `battery_pct` | uint8 | % | 0–100 (100 if no battery monitor wired) |
| `reset_reason` | string | — | `deepsleep` / `poweron` / `panic` / `brownout` etc |
| `free_heap` | uint32 | bytes | Firmware health indicator |

`temperature` and `ec` are **not present** — HW analog sensors measure
moisture only. Add a DS18B20 (1-Wire) for soil temperature if needed later.

### Calibration

Each physical installation needs calibration — sensors vary by batch and soil type:

```cpp
#define MOISTURE_DRY 2800   // ADC raw in dry air   → 0 % VWC
#define MOISTURE_WET 1000   // ADC raw in water      → 100 % VWC
```

Set in `secrets.h` after measuring with Serial Monitor on first flash.

### Boot wake-up "hello" payload

On every cold boot (poweron / panic / brownout — NOT scheduled deep-sleep
wakes), the soil node first publishes an idempotent pairing message before
its first reading:

```json
{
  "node_id":      "soil-zone-a",
  "hello":        true,
  "kind":         "soil",
  "reset_reason": "poweron",
  "free_heap":    248320
}
```

This lets the backend persist the node in the registered set so the dashboard
card materialises immediately — operators see every paired plant whether or
not it has reported telemetry yet. Sensor fields are omitted on hello.

---

## Camera node — HTTP pairing + frame upload

Camera nodes (Type B) POST JPEG frames directly to FastAPI over HTTP. On
cold boot they also POST a one-time pairing message:

```
POST /api/v1/node/{node_id}/hello
Authorization: Bearer <token>
Content-Type:  application/json

{"kind": "camera", "firmware_version": "1.0", "reset_reason": "poweron"}
```

Then for every captured frame:

```
POST /api/v1/node/{node_id}/upload-frame
Authorization: Bearer <token>
Content-Type:  image/jpeg
Content-Length: <bytes>
<raw JPEG body>
```

Large binary payloads are better suited to HTTP than MQTT, which is optimised
for small telemetry messages.

---

## `pms/command/{zone}` — actuator commands

Published by: **FastAPI** `MqttPublisher` (ControlEngine decisions + manual
`POST /zone/{zone}/command`)  
Subscribed by: **Controller Node** (always-on ESP32 driving the irrigation
relay). Safe with no subscriber — the ControlEngine's Redis state remains the
authoritative *virtual* actuator.

### Payload (JSON)

```json
{
  "action":          "on",
  "zone":            "soil-zone-a",
  "reason":          "moisture 12.0 < setpoint 30.0",
  "max_run_seconds": 300,
  "ts":              1780000000
}
```

| Field | Type | Notes |
|---|---|---|
| `action` | string | `"on"` \| `"off"` |
| `zone` | string | Zone / soil-node id |
| `reason` | string | Audit string, mirrors `logs:automation` |
| `max_run_seconds` | int | Controller must ALSO enforce this locally (fail-safe off) |
| `ts` | int | Unix seconds at publish |

A controller must fail safe: relay OFF on broker disconnect and on local
`max_run_seconds` expiry, regardless of commands.

---

## `pms/status/{node_id}` — controller heartbeat

Published by: **Controller Node**, every ≤ 60 s while online, `retain=false`
(a retained heartbeat would fake hardware presence after the controller dies).  
Subscribed by: **FastAPI** `MQTTSubscriber` → refreshes
`controller:last_seen:{node_id}` in Redis.

```json
{"node_id": "soil-zone-a", "on": false}
```

A zone reports `bound: "hardware"` on the dashboard only while a heartbeat is
fresher than `SENSOR_SANITY_MAX_AGE_SECONDS`; otherwise the actuator shows
`VIRTUAL`.

---

## Reserved topics (future work)

| Topic | Direction | Purpose |
|---|---|---|
| `pms/ota/{node_id}` | broker → node | OTA firmware trigger |

---

## Node ID naming convention

```
soil-{zone}-{sensor_index}   e.g. soil-zone-a  soil-zone-b
camera-{zone}                e.g. camera-zone-a
```

A "zone" groups the plants monitored by one camera + one soil node:
- 1 × Camera Node  (OV2640, covers ~4–6 plants in a row)
- 1 × Soil Node    (analog HW-103/HW-080 capacitive probe on an ADC pin)
