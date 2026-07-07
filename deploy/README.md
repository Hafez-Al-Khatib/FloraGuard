# Raspberry Pi 5 Deployment

Scripts that turn a fresh Raspberry Pi 5 into the Plant Monitoring System edge
server — Docker stack, auto-start on boot, and an optional fullscreen
touchscreen kiosk.

## Prerequisites

- Raspberry Pi 5 (4 GB or 8 GB)
- Raspberry Pi OS **64-bit** (Bookworm); desktop image if you want the kiosk
- microSD card (32 GB+) or NVMe SSD
- Network: Ethernet to the router recommended; 2.4 GHz WiFi for the ESP32 nodes
- This repo cloned onto the Pi

## Quick start

```bash
# 1. Clone and enter the repo on the Pi
git clone <your-repo-url> plant-monitoring-system
cd plant-monitoring-system

# 2. Bootstrap: installs Docker, builds the stack, enables auto-start
#    (does NOT start it — secrets must be set first)
chmod +x deploy/pi-setup.sh
./deploy/pi-setup.sh

# 3. Set secrets BEFORE the first start, then start the stack.
#    InfluxDB bakes its token into its volume on first boot, so starting
#    with placeholder secrets and changing them later breaks DB writes.
#    pi-setup.sh has already generated mosquitto/config/passwd from MQTT_USERNAME/MQTT_PASSWORD.
nano edge-server/.env        # strong passwords, INFLUXDB_TOKEN, API_AUTH_TOKEN, GEMINI_API_KEY
sudo systemctl start pms-stack

# 4. (Optional) touchscreen kiosk
chmod +x deploy/kiosk-setup.sh
./deploy/kiosk-setup.sh
sudo reboot
```

After reboot the Pi serves the dashboard at `https://<pi-ip>/` and, if you ran
the kiosk step, opens it fullscreen on the attached display.

## ARM64 dashboard note

The standard `dashboard/Dockerfile` uses the Cirrus Labs Flutter image, which is
AMD64-only. On a Pi 5 the bootstrap automatically switches to
`dashboard/Dockerfile.pi`, which serves the pre-built `dashboard/build/web/`
bundle with nginx. Make sure `dashboard/build/web/` is present before deploying;
rebuild it with:

```bash
cd dashboard
flutter build web --no-tree-shake-icons --release --pwa-strategy=none
```

## What each file does

| File | Purpose |
|---|---|
| `pi-setup.sh` | One-shot bootstrap — Docker, certs, Mosquitto passwd, build, systemd auto-start. Idempotent. |
| `pms-stack.service` | systemd unit; runs `docker compose up -d` on every boot. |
| `kiosk-setup.sh` | Installs Chromium + wires the kiosk launcher into the desktop autostart. |
| `pms-kiosk.sh` | Launcher — waits for the stack, then opens Chromium fullscreen, auto-authenticated. |
| `dashboard/Dockerfile.pi` | nginx-only image serving the pre-built Flutter web bundle on ARM64. |

## Common operations

```bash
# Stack status / logs
sudo systemctl status pms-stack
sudo docker compose -f edge-server/docker-compose.yml ps
sudo docker compose -f edge-server/docker-compose.yml logs -f api

# Restart after changing .env
sudo systemctl restart pms-stack

# Stop auto-launching on boot
sudo systemctl disable pms-stack

# Health check
curl -k https://localhost/api/v1/health
```

## Set a stable hostname (optional)

So nodes and tablets can reach the Pi at `plant-hub.local` instead of an IP:

```bash
sudo raspi-config nondestructive   # System Options → Hostname → plant-hub
```

mDNS (`plant-hub.local`) works out of the box for Apple/Linux clients and most
Android browsers on the same LAN.

## Notes

- **First build is slow** (10–20 min) — it pulls the ~2 GB Flutter image to
  build the dashboard. Subsequent boots just start the cached containers.
- **Self-signed TLS**: browsers warn on first visit. The kiosk launcher passes
  `--ignore-certificate-errors` for localhost. For tablets, accept the warning
  once, or install the generated `edge-server/mosquitto/certs/ca.crt` as a
  trusted root.
- **Cursor on Wayland**: `unclutter` only hides the pointer under X11. On labwc
  the cursor stays; a USB touchscreen rarely shows one anyway.
