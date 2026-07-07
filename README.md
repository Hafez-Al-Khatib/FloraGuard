# B2B Autonomous Plant Monitoring & Automation System

A production-oriented, internet-independent smart farming platform for high-density commercial greenhouses and large-scale agriculture.

> **Status:** Working MVP. Telemetry pipeline, ONNX disease inference, cloud
> agronomist chat, live SSE dashboard, and the Raspberry Pi 5 deployment are all
> implemented. Hardware bring-up (ESP32 nodes) is in progress.

## System Architecture

```
[ EDGE LAYER: FIELD NODES ]
  [ Soil Nodes ]                 [ Camera Nodes ]
   ESP32-S3 + analog              ESP32-CAM (AI-Thinker)
   moisture sensors               + OV2640
          │                              │
     WiFi + MQTT                   WiFi + HTTP (raw JPEG)
          │                              │
          └────────(Local LAN)───────────┤
                                           ▼
                  [ EDGE SERVER: RASPBERRY PI 5 ]
                  ├── Mosquitto MQTT Broker  (TLS, port 8883)
                  ├── Redis                  (cache + telemetry stream, AOF)
                  ├── InfluxDB 2.x           (time-series telemetry)
                  ├── FastAPI Agronomist API (auth, validation, ONNX ResNet-18)
                  ├── Dashboard container    (Flutter web, built in-stack)
                  └── Nginx                  (TLS reverse proxy + SSE)
                                           │
                          cloud chat (Gemini / Anthropic) ── only outbound call
                                           │
                              HTTPS / REST / SSE
                                           ▼
                         [ CLIENT: FLUTTER DASHBOARD ]
                         ├── Web (served by the Pi, kiosk or tablet)
                         └── Live cards via Server-Sent Events
```

Everything runs offline except the agronomist chat, which calls a configurable
cloud LLM (free Gemini tier by default, Anthropic Claude for production).

## Repository Layout

```
.
├── AGENTS.md                  # Developer/agent conventions
├── README.md                  # This file
├── deploy/                    # Raspberry Pi 5 bootstrap + kiosk scripts
├── docs/                      # Architecture, security, deployment runbooks
├── edge-server/               # Docker Compose + FastAPI backend
│   ├── app/                   # Python FastAPI application
│   ├── docker-compose.yml
│   ├── nginx/
│   ├── mosquitto/
│   ├── redis/
│   └── influxdb/
├── firmware/                  # Embedded node firmware
│   ├── soil-node/             # ESP32-S3 + analog moisture (WiFi/MQTT)
│   └── camera-node/           # ESP32-CAM + OV2640 (WiFi/HTTP)
└── dashboard/                 # Flutter client
```

## Quick Start (Edge Server)

### Raspberry Pi 5 (scripted)

```bash
git clone <repo-url> plant-monitoring-system && cd plant-monitoring-system
./deploy/pi-setup.sh          # Docker + certs + build + enable on boot
nano edge-server/.env         # set strong secrets + GEMINI_API_KEY (before first start)
sudo systemctl start pms-stack
```

See [`deploy/README.md`](deploy/README.md) for the full Pi guide including the
touchscreen kiosk.

### Development (any machine, no TLS)

```bash
cd edge-server
cp app/example.env .env       # then edit .env
docker compose -f docker-compose.dev.yml up --build
```

API at `http://localhost:8000`, dashboard at `http://localhost:8080`,
InfluxDB at `http://localhost:8086`.

### Production / farm deployment (TLS)

```bash
cd edge-server
cp app/example.env .env       # edit with strong secrets
make certs                    # self-signed CA + server certificates
make up
```

The stack exposes:

| Service | Endpoint | Notes |
|---------|----------|-------|
| FastAPI API | `https://localhost/api/v1/...` | Via Nginx reverse proxy |
| MQTT | `mqtts://localhost:8883` | TLS + username/password auth |
| Flutter Web | `https://localhost/` | Dashboard container, proxied by Nginx |
| Live telemetry | `https://localhost/api/v1/stream` | Server-Sent Events |

InfluxDB is intentionally **not** proxied — access it via `docker exec` or a
port-forward. See `docs/tls-setup.md` for certificates and
`docs/deployment-runbook.md` for field procedures.

## Security Highlights

- TLS on all external interfaces (self-signed CA for local deployments; customer CA for production).
- MQTT username/password authentication; anonymous connections disabled.
- Redis ACL with password and AOF persistence.
- FastAPI dependency-injection auth, Pydantic validation, rate limiting, and audit logging.
- Image upload size limits and content-type verification via magic bytes.
- LLM prompt delimiters + prompt-injection filtering.
- Automation overrides require logging + human confirmation or time-bound dead-man switch.

## Design Decisions

1. **WiFi + MQTT, not LoRa.** ESP32-S3 has native 2.4 GHz WiFi and the
   Mosquitto broker already handles MQTT, so greenhouse nodes use WiFi + MQTT.
   LoRa is kept as future work for large outdoor sites with no WiFi coverage.
2. **ResNet-18 (ONNX), not YOLO.** Disease classification (not detection) is the
   task. An INT8-quantized ResNet-18 on the 15-class PlantVillage set runs in
   ~41 ms on the Pi 5 CPU — fast enough for on-demand `/analyze`.
3. **Cloud chat, not a local LLM.** Running a multi-billion-parameter model
   alongside vision + databases on 8 GB is impractical. The agronomist chat
   calls a configurable cloud API (Gemini free tier / Anthropic) — the only
   outbound call in the system. Everything else is offline.
4. **Analog soil sensors.** The deployed HW-103 / HW-080 sensors are analog
   (moisture only), read via ADC — no RS485/Modbus bus.

## Roadmap

- [x] Architecture audit and hardening plan
- [x] Repository scaffold + Docker Compose
- [x] Secure telemetry pipeline (MQTT → Redis → InfluxDB)
- [x] Soil node firmware (deep sleep, WiFi/MQTT, analog ADC)
- [x] Camera node firmware (frame quality pre-filter, raw JPEG upload)
- [x] ONNX ResNet-18 inference service on Pi 5
- [x] Cloud agronomist API with rate limits + prompt-injection filtering
- [x] Flutter dashboard (live SSE telemetry, node detail, chat)
- [x] TLS deployment guide + Raspberry Pi 5 bootstrap scripts
- [x] Backend + dashboard CI (GitHub Actions)
- [ ] Hardware field integration test (ESP32 nodes → live dashboard)

## License

TBD — to be selected by the project author.
