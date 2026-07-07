# Security Checklist

Use this checklist before deploying the Plant Monitoring System to a farm or presenting the senior project.

## Authentication & Authorization

- [ ] `API_AUTH_TOKEN` is changed from the default dev token in production
      (`openssl rand -hex 32`), and the same value is set in each node's `secrets.h` / `.env`.
- [ ] MQTT `allow_anonymous` is `false` and credentials are set (`MQTT_USERNAME`/`MQTT_PASSWORD`).
- [ ] Redis requires a password (`--requirepass`) and is bound to loopback.
- [ ] InfluxDB admin token is rotated and stored in Docker secrets or a vault.

## Transport Security

- [ ] Mosquitto listens on port 8883 with TLS 1.2+.
- [ ] Nginx serves HTTPS on port 443 with a valid certificate.
- [ ] Redis is not exposed on `0.0.0.0` (binds to loopback inside Docker network).
- [ ] InfluxDB and the API are published only on `127.0.0.1` — Nginx is the sole LAN entry point.
- [ ] Cloud chat (Gemini/Anthropic) is the only outbound connection; the API key is in `.env`, never committed.

## Input Validation & DoS

- [ ] Camera frame uploads enforce max size (2 MB) and image magic-byte checks.
- [ ] `node_id` is validated against `^[a-zA-Z0-9_-]{1,64}$` on every route.
- [ ] LLM chat has rate limiting (`5/minute`) per IP and input length caps.
- [ ] No raw user strings are concatenated into LLM prompts; delimiters and jailbreak filters are used.

## Automation Safety

- [ ] No irrigation/valve actuation runs without:
  - logging to `logs:automation` Redis stream, and
  - human confirmation or a time-bound dead-man switch.
- [ ] High-confidence disease detections trigger alerts first, not immediate actuation.

## Firmware & Physical Security

- [ ] `secrets.h` (WiFi + MQTT + API token) is gitignored and never committed.
- [ ] ESP32 firmware is built with `-DSECURE_BOOT` and signed before OTA (production).
- [ ] Field enclosures are tamper-evident and mounted out of casual reach.
- [ ] Serial/JTAG debug ports are disabled or password-protected on production units.

## Observability & Incident Response

- [ ] Audit logs are persisted (not only in volatile Redis).
- [ ] Grafana or equivalent monitors for:
  - Node offline > 15 minutes
  - Unusual MQTT publish rates
  - API 4xx/5xx spikes
  - Disk/RAM saturation on Pi
- [ ] Runbook exists for revoking a compromised node token.
