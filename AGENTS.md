# Agent Guidance — Plant Monitoring System

## Project Context

This is a senior-project B2B autonomous plant monitoring system — a working
full-stack MVP:

- Soil nodes (ESP32-S3 + analog moisture sensors) → WiFi + MQTT
- Camera nodes (ESP32-CAM + OV2640) → WiFi + HTTP (raw JPEG upload)
- Raspberry Pi 5 edge server (Docker Compose: Mosquitto, Redis, InfluxDB, FastAPI, dashboard, Nginx)
- Flutter dashboard (web; live SSE telemetry, node detail, agronomist chat)
- On-device ONNX ResNet-18 disease inference + cloud LLM agronomist (Gemini/Anthropic)

## Architecture Decisions (Locked In)

1. **Backend framework:** FastAPI (Python 3.11+) with async route handlers.
2. **Message broker:** Eclipse Mosquitto with TLS 8883 and username/password auth.
3. **Cache / stream buffer:** Redis with ACL + persistence (AOF everysec).
4. **Time-series DB:** InfluxDB 2.x; telemetry retention policy is defined in `edge-server/influxdb/config/`.
5. **Inference runtime:** ONNX Runtime (CPU execution provider) on Pi 5, INT8 ResNet-18, 15-class PlantVillage.
6. **Agronomist chat:** Cloud LLM via raw `httpx` — Gemini (free tier) or Anthropic Claude, selected by `CHAT_PROVIDER`. The only outbound call; no local LLM, no SDK dependency.
7. **Dashboard:** Flutter web; live updates over Server-Sent Events (`/api/v1/stream`).

## Security Non-Negotiables

Every code contribution MUST respect these rules:

- **Authentication:** All FastAPI routes (except `/health` and `/docs` when explicitly enabled) require a valid API token or user JWT.
- **Input validation:** All path parameters, query strings, and uploaded bytes are validated with Pydantic. `node_id` must match `^[a-zA-Z0-9_-]{1,64}$`.
- **File uploads:** Camera frame endpoint accepts a raw binary body (`Content-Type: image/jpeg`), enforces max size (2 MB) via Content-Length before reading, validates image magic bytes, and rejects non-image content.
- **Rate limiting:** LLM chat endpoint is throttled (per user / per IP) to protect Pi resources.
- **Secrets:** No hardcoded passwords, keys, or tokens. Use environment variables loaded via Pydantic `BaseSettings`.
- **TLS:** All external-facing services use TLS inside the container network or are reverse-proxied by Nginx with local certificates.
- **Automation safety:** Any actuation command requires logging and at least one of: (a) human confirmation, (b) confidence threshold + time-bound override, (c) dead-man switch.
- **Prompt safety:** LLM prompts are built with delimiter boundaries and user input is escaped; prompt-injection filters reject jailbreak patterns.

## Coding Style

- Python: PEP 8, `ruff` formatter, type hints on public functions.
- Flutter: `very_good_analysis` or `flutter_lints`, feature-based folder structure.
- C++ (firmware): Arduino/PlatformIO conventions, minimal global state, deep-sleep aware.

## Testing Expectations

- FastAPI: `pytest` with `httpx.AsyncClient`. Aim for unit + route-level coverage.
- Firmware: Build targets for native `pio run` and hardware-in-the-loop logs.
- Dashboard: Widget tests for critical chart and auth flows where practical.

## How to Build / Run

```bash
cd edge-server
cp app/example.env .env      # edit secrets + GEMINI_API_KEY
docker compose up --build    # full stack (prod); or -f docker-compose.dev.yml for dev
```

On a Raspberry Pi 5, use `./deploy/pi-setup.sh` instead (see `deploy/README.md`).
For local TLS certificate generation, see `docs/tls-setup.md`.

## Communication

When modifying architecture-level decisions (e.g., changing the TSDB, adding a new network protocol, swapping the LLM runtime), update this file and the README so the next agent stays synchronized.
