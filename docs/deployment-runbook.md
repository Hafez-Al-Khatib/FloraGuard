# Field Deployment Runbook

End-to-end bring-up of the Plant Monitoring System: edge server on a Raspberry
Pi 5, ESP32 soil + camera nodes over WiFi/MQTT, and the Flutter dashboard.

> Architecture recap: soil nodes (ESP32-S3 + analog moisture sensors) publish
> over **WiFi + MQTT**; camera nodes (ESP32-CAM) POST JPEGs over **HTTP**; the
> FastAPI backend caches in Redis, persists to InfluxDB, runs on-device **ONNX
> ResNet-18** disease inference, and streams live updates to the dashboard over
> SSE. The only outbound internet call is the cloud chat provider (Gemini /
> Anthropic). LoRa is out of scope (future work for large outdoor sites).

---

## Phase 1 — Edge Server (Raspberry Pi 5)

The scripted path is in [`deploy/`](../deploy/README.md). Summary:

1. Flash Raspberry Pi OS 64-bit (Bookworm), enable SSH, boot the Pi.
2. Clone the repo and run the bootstrap:
   ```bash
   cd plant-monitoring-system
   ./deploy/pi-setup.sh
   ```
   This installs Docker, generates TLS certs, builds the stack, and enables the
   `pms-stack` systemd service. It does **not** start the stack — secrets must
   be set first (InfluxDB bakes its token into its volume on first boot).
3. Set real secrets, then start:
   ```bash
   nano edge-server/.env        # passwords, INFLUXDB_TOKEN, API_AUTH_TOKEN, GEMINI_API_KEY
   sudo systemctl start pms-stack
   ```
4. Verify:
   ```bash
   sudo docker compose -f edge-server/docker-compose.yml ps
   curl -k https://localhost/api/v1/health
   ```
5. (Optional) attach a capacitive touchscreen and run `./deploy/kiosk-setup.sh`
   for a fullscreen wall-panel UI.

Record the Pi's LAN IP (`hostname -I`) — the nodes need it.

> **Production MQTT auth:** the prod broker (`mosquitto.conf`) uses TLS +
> password auth, and the `mosquitto/config/passwd` file ships as an empty
> placeholder. Before `make up`, generate a real entry for each node user:
> ```bash
> docker run --rm -v "$PWD/mosquitto/config:/mosquitto/config" eclipse-mosquitto:2 \
>   mosquitto_passwd -b /mosquitto/config/passwd "$MQTT_USERNAME" "$MQTT_PASSWORD"
> ```
> (The dev broker uses anonymous access, so this step is dev-skippable.)

---

## Phase 2 — Network

1. Put the Pi and all ESP32 nodes on the **same 2.4 GHz** WiFi network
   (ESP32 has no 5 GHz radio).
2. Recommended: a dedicated IoT SSID/VLAN isolated from the office network,
   WPA2-PSK or WPA3.
3. Ensure coverage reaches every node location; ESP32 WiFi is modest range.
4. Optional but faster node wake cycles: assign static IPs (see firmware notes).

---

## Phase 3 — Node Activation

### Soil Nodes (ESP32-S3 + analog HW-103 / HW-080 sensors)

1. `cp firmware/soil-node/src/secrets.h.example firmware/soil-node/src/secrets.h`
2. Fill in: `WIFI_SSID`, `WIFI_PASS`, `MQTT_HOST` (Pi IP), `SENSOR_PINS[]`,
   `SENSOR_NODE_IDS[]`. Keep `EDGE_MDNS_NAME` = the Pi's hostname
   (`plant-hub` by default) — the node resolves it over mDNS first and only
   uses `MQTT_HOST` if the lookup fails, so hotspot IP changes don't strand it.
3. **Calibrate** each sensor: flash, open Serial Monitor (115200), note the raw
   ADC in dry air vs submerged in water, and set `MOISTURE_DRY` / `MOISTURE_WET`.
4. `pio run -t upload` from `firmware/soil-node/`.
5. On cold boot the node sends a `hello` and then telemetry — confirm a card
   appears on the dashboard within ~60 s.

### Camera Nodes (ESP32-CAM AI-Thinker + OV2640)

1. `cp firmware/camera-node/src/secrets.h.example firmware/camera-node/src/secrets.h`
2. Fill in: `WIFI_SSID`, `WIFI_PASS`, `API_BASE_URL` (`http://<pi-ip>:8000` on a
   trusted LAN, or `https://<pi-ip>` through nginx), `API_TOKEN`, `NODE_ID`.
   Keep `EDGE_MDNS_NAME` = the Pi's hostname (`plant-hub`) — mDNS is tried
   before the static `API_BASE_URL` host.
3. Flash via an FTDI 3.3 V adapter (the ESP32-CAM has no USB port):
   `pio run -t upload`.
4. Aim at the canopy. Verify frames upload and `/analyze` returns a label.

---

## Phase 4 — Dashboard Access

The dashboard ships **inside the stack** — the `dashboard` container builds the
Flutter web app and nginx serves it. No host Flutter SDK is needed.

- Tablets/phones on the LAN: open `https://<pi-ip>/` (accept the self-signed
  cert once) and log in with the `API_AUTH_TOKEN` from `.env`.
- Kiosk deep-link (auto-login): `https://<pi-ip>/?hub=https://<pi-ip>&token=<token>`.
- Wall panel: handled automatically by `deploy/kiosk-setup.sh`.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| No telemetry cards | Node can't reach MQTT broker | Check `MQTT_HOST` = Pi IP, same WiFi, broker healthy (`docker compose logs mosquitto`) |
| Card shows but stays `STALE` | Node stopped publishing | Check node power/serial logs; cards persist by design once paired |
| Frames rejected (415/413) | Wrong content type or oversized | Firmware must send `Content-Type: image/jpeg`; frame must be < 2 MB |
| Chat returns `[Chat error: …]` | Bad/missing API key or model | The error now prints the provider's response — read it; set `GEMINI_API_KEY`, try `GEMINI_MODEL=gemini-flash-latest` |
| `api` container unhealthy | Redis/Influx not ready | `docker compose ps`; check `.env` secrets (Influx password ≥ 8 chars) |
| Moisture reads 0 % or 100 % stuck | Sensor not calibrated | Set `MOISTURE_DRY` / `MOISTURE_WET` from the raw ADC Serial output |
| Dashboard unreachable | Stack not started | `sudo systemctl status pms-stack`; `curl -k https://localhost/api/v1/health` |

---

## Demo mode (faster updates)

For a live presentation, shorten the soil node sleep so cards update every few
seconds instead of every 60:

```cpp
// firmware/soil-node/src/main.cpp
#define SLEEP_US  (10ULL * 1000ULL * 1000ULL)  // 10 s for demo
```

Restore to 60 s for real deployment to preserve battery life.
