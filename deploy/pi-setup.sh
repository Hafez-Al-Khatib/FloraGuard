#!/usr/bin/env bash
#
# Plant Monitoring System — Raspberry Pi 5 one-shot bootstrap.
#
# Run this ONCE on a fresh Raspberry Pi OS (64-bit, Bookworm) install to:
#   1. Install Docker Engine + Compose plugin
#   2. Add the current user to the docker group
#   3. Generate TLS certs (if missing)
#   4. Build the edge-server stack
#   5. Install + enable the systemd auto-start service
#
# Usage (from the repo root on the Pi):
#   chmod +x deploy/pi-setup.sh
#   ./deploy/pi-setup.sh
#
# Re-running is safe — each step is idempotent.

set -euo pipefail

# ── Resolve paths ─────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
EDGE_DIR="$REPO_ROOT/edge-server"
SERVICE_USER="${SUDO_USER:-$USER}"

log()  { printf '\033[1;32m[setup]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

[ -d "$EDGE_DIR" ] || die "edge-server/ not found — run from the repo checkout."

# ── 1. Docker Engine ──────────────────────────────────────────────────────────
if command -v docker >/dev/null 2>&1; then
    log "Docker already installed: $(docker --version)"
else
    log "Installing Docker Engine via get.docker.com convenience script..."
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    sudo sh /tmp/get-docker.sh
    rm -f /tmp/get-docker.sh
fi

# ── 2. Compose plugin ─────────────────────────────────────────────────────────
if docker compose version >/dev/null 2>&1; then
    log "Docker Compose plugin present: $(docker compose version --short)"
else
    log "Installing docker-compose-plugin..."
    sudo apt-get update -qq
    sudo apt-get install -y docker-compose-plugin
fi

# ── 3. docker group membership ────────────────────────────────────────────────
if id -nG "$SERVICE_USER" | grep -qw docker; then
    log "User '$SERVICE_USER' already in docker group."
else
    log "Adding '$SERVICE_USER' to the docker group..."
    sudo usermod -aG docker "$SERVICE_USER"
    warn "Group change needs a re-login to take effect. After this script,"
    warn "log out and back in (or reboot) before running docker as your user."
fi

# ── 4. Environment file ───────────────────────────────────────────────────────
if [ ! -f "$EDGE_DIR/.env" ]; then
    log "Creating edge-server/.env from template..."
    cp "$EDGE_DIR/app/example.env" "$EDGE_DIR/.env"
    warn "edge-server/.env created with PLACEHOLDER secrets."
    warn "Edit it now and set strong values before exposing this Pi:"
    warn "    nano $EDGE_DIR/.env"
else
    log "edge-server/.env already exists — leaving it untouched."
fi

# ── 4b. Mosquitto password file ───────────────────────────────────────────────
# The eclipse-mosquitto image does NOT create a passwd file from env vars.
# We must bake the MQTT credentials from .env into mosquitto/config/passwd.
# shellcheck source=/dev/null
source "$EDGE_DIR/.env"
if [ -z "${MQTT_USERNAME:-}" ] || [ -z "${MQTT_PASSWORD:-}" ]; then
    die "MQTT_USERNAME and MQTT_PASSWORD must be set in $EDGE_DIR/.env"
fi
log "Generating Mosquitto password file for user '$MQTT_USERNAME'..."
rm -f "$EDGE_DIR/mosquitto/config/passwd"
touch "$EDGE_DIR/mosquitto/config/passwd"
chmod 600 "$EDGE_DIR/mosquitto/config/passwd"
sudo docker run --rm \
    -v "$EDGE_DIR/mosquitto/config:/mosquitto/config" \
    eclipse-mosquitto:2 \
    mosquitto_passwd -b /mosquitto/config/passwd "$MQTT_USERNAME" "$MQTT_PASSWORD"

# ── 5. TLS certificates ───────────────────────────────────────────────────────
if [ ! -f "$EDGE_DIR/nginx/certs/server.crt" ]; then
    log "Generating self-signed TLS certs..."
    # Pass PMS_HOST_IP=<pi-lan-ip> to add an IP SAN so phones that reach the Pi
    # by IP (mDNS .local is unreliable on Android) still validate the cert.
    ( cd "$EDGE_DIR/mosquitto/config" && bash gen-certs.sh "${PMS_HOSTNAME:-plant-hub.local}" "${PMS_HOST_IP:-}" )
else
    log "TLS certs already present."
fi

# ── 6. Build the stack ────────────────────────────────────────────────────────
# Warn about the Flutter dashboard image on ARM64 (Pi 5).
# ghcr.io/cirruslabs/flutter:stable is AMD64-only as of 2024. On a Pi 5 the
# dashboard build will fail unless the image has gained ARM64 support, QEMU is
# enabled (very slow), or the web bundle is pre-built and served by plain nginx.
if [ "$(uname -m)" = "aarch64" ] || [ "$(uname -m)" = "arm64" ]; then
    warn "ARM64 detected. The dashboard Flutter builder image may not have an ARM64 variant."
    warn "If the dashboard build fails, either:"
    warn "  1. Pre-build dashboard/build/web/ on an AMD64 machine and use an nginx-only Dockerfile"
    warn "  2. Build the Flutter web bundle natively on the Pi (install Flutter SDK)"
    warn "  3. Temporarily comment out the 'dashboard' service in docker-compose.yml"
fi

log "Building containers (first build pulls the Flutter image — 10-20 min)..."
# On Pi (ARM64) use the pre-built Flutter bundle to avoid the AMD64-only builder image.
if [ "$(uname -m)" = "aarch64" ] || [ "$(uname -m)" = "arm64" ]; then
    export DASHBOARD_DOCKERFILE=Dockerfile.pi
    log "Using DASHBOARD_DOCKERFILE=Dockerfile.pi for ARM64 deployment."
fi
( cd "$EDGE_DIR" && sudo docker compose build )

# ── 7. systemd auto-start service ─────────────────────────────────────────────
log "Installing systemd service for auto-start on boot..."
sed -e "s|__EDGE_DIR__|$EDGE_DIR|g" \
    -e "s|__DASHBOARD_DOCKERFILE__|${DASHBOARD_DOCKERFILE:-Dockerfile}|g" \
    "$SCRIPT_DIR/pms-stack.service" \
    | sudo tee /etc/systemd/system/pms-stack.service >/dev/null
sudo systemctl daemon-reload
sudo systemctl enable pms-stack.service

# The stack is intentionally NOT started here. InfluxDB only runs its one-time
# setup on first boot against an empty volume — if it starts now with the
# placeholder INFLUXDB_TOKEN, that token is baked into the volume permanently.
# Editing .env afterwards would then mismatch the API token and break all
# writes. So: set real secrets FIRST, then start.

# ── Done ──────────────────────────────────────────────────────────────────────
log "Bootstrap complete (stack built + enabled, but NOT started yet)."
echo
warn "IMPORTANT — set real secrets BEFORE the first start:"
echo "  1. Edit secrets:   nano $EDGE_DIR/.env"
echo "                     (passwords, INFLUXDB_TOKEN, API_AUTH_TOKEN, GEMINI_API_KEY)"
echo "  2. Start stack:    sudo systemctl start pms-stack"
echo "  3. Verify:         curl -k https://localhost/api/v1/health"
echo
log "After that:"
echo "  • Logs:      sudo docker compose -f $EDGE_DIR/docker-compose.yml logs -f api"
echo "  • Kiosk UI:  ./deploy/kiosk-setup.sh   (if a touchscreen is attached)"
echo "  • Dashboard: https://<pi-ip>/  (or https://plant-hub.local/)"
