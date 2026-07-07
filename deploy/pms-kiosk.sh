#!/usr/bin/env bash
#
# Plant Monitoring System — kiosk launcher.
#
# Waits for the dashboard to come up, then opens Chromium fullscreen, already
# authenticated via the deep-link token read from edge-server/.env. Installed
# to ~/.local/bin/pms-kiosk.sh by deploy/kiosk-setup.sh (which substitutes
# __EDGE_DIR__ with the real path).
#
# The token is read at launch time so rotating API_AUTH_TOKEN in .env takes
# effect on the next boot without editing this script.

set -uo pipefail

EDGE_DIR="__EDGE_DIR__"
ENV_FILE="$EDGE_DIR/.env"
HUB_URL="https://localhost"

# ── Read the API token from .env ──────────────────────────────────────────────
TOKEN=""
if [ -f "$ENV_FILE" ]; then
    TOKEN="$(grep -E '^API_AUTH_TOKEN=' "$ENV_FILE" | head -n1 | cut -d= -f2-)"
fi
if [ -z "$TOKEN" ]; then
    echo "[kiosk] WARNING: API_AUTH_TOKEN not found in $ENV_FILE — login will be blank."
fi

# ── Wait for the stack to answer before opening the browser ───────────────────
# Without this the kiosk opens a connection-refused page on cold boot while the
# containers are still starting.
echo "[kiosk] Waiting for the dashboard to come up..."
for _ in $(seq 1 60); do
    if curl -ksf "$HUB_URL/api/v1/health" >/dev/null 2>&1; then
        echo "[kiosk] Dashboard is up."
        break
    fi
    sleep 2
done

# ── Hide the mouse cursor (X11 only; no-op under Wayland) ──────────────────────
if command -v unclutter >/dev/null 2>&1 && [ -n "${DISPLAY:-}" ]; then
    unclutter -idle 0.5 -root &
fi

# ── Deep-link URL: ?hub=<api origin>&token=<tok> prefills + auto-connects ──────
URL="$HUB_URL/?hub=$HUB_URL&token=$TOKEN"

# Find Chromium (package name differs across Pi OS releases).
CHROME="$(command -v chromium-browser || command -v chromium || true)"
[ -n "$CHROME" ] || { echo "[kiosk] Chromium not installed."; exit 1; }

# --ignore-certificate-errors: the LAN TLS cert is self-signed.
# --test-type: suppresses the unsupported-flag warning bar for a clean kiosk.
exec "$CHROME" \
    --kiosk \
    --noerrdialogs \
    --disable-infobars \
    --disable-session-crashed-bubble \
    --disable-translate \
    --no-first-run \
    --check-for-update-interval=31536000 \
    --ignore-certificate-errors \
    --test-type \
    --autoplay-policy=no-user-gesture-required \
    "$URL"
