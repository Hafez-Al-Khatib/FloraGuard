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

## Reserved topics (future work)

| Topic | Direction | Purpose |
|---|---|---|
| `pms/status/{node_id}` | node → broker | Heartbeat / connectivity check |
| `pms/command/{node_id}` | broker → node | Remote config (sleep interval, threshold) |
| `pms/ota/{node_id}` | broker → node | OTA firmware trigger |

---

## Node ID naming convention

```
soil-{zone}-{sensor_index}   e.g. soil-zone-a  soil-zone-b
camera-{zone}                e.g. camera-zone-a
```

A "zone" groups the plants monitored by one camera + one soil node:
- 1 × Camera Node  (OV2640, covers ~4–6 plants in a row)
- 1 × Soil Node    (RS485 bus, up to 4 soil sensors per board)
