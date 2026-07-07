#!/usr/bin/env bash
#
# Plant Monitoring System — touchscreen kiosk setup.
#
# Installs Chromium + the kiosk launcher and wires it to start automatically
# when the Pi's desktop session loads. Run AFTER pi-setup.sh, on a Pi with the
# desktop (not Lite) image and a capacitive touchscreen attached.
#
# Usage (from the repo root on the Pi):
#   chmod +x deploy/kiosk-setup.sh
#   ./deploy/kiosk-setup.sh
#
# Supports the labwc (Pi OS Bookworm default), wayfire, and X11/LXDE sessions.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
EDGE_DIR="$REPO_ROOT/edge-server"
BIN_DIR="$HOME/.local/bin"
LAUNCHER="$BIN_DIR/pms-kiosk.sh"

log()  { printf '\033[1;32m[kiosk]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }

# ── 1. Packages ───────────────────────────────────────────────────────────────
log "Installing Chromium and unclutter..."
sudo apt-get update -qq
# chromium-browser is a transitional/real package depending on release; install
# whichever resolves. unclutter only helps under X11 but is harmless to have.
sudo apt-get install -y chromium-browser unclutter curl 2>/dev/null \
    || sudo apt-get install -y chromium unclutter curl

# ── 2. Install the launcher with the real edge-server path baked in ───────────
log "Installing kiosk launcher to $LAUNCHER..."
mkdir -p "$BIN_DIR"
sed "s|__EDGE_DIR__|$EDGE_DIR|g" "$SCRIPT_DIR/pms-kiosk.sh" > "$LAUNCHER"
chmod +x "$LAUNCHER"

# ── 3. Wire autostart for the active session type ─────────────────────────────
wired=0

# labwc (Pi OS Bookworm default compositor on Pi 5)
if command -v labwc >/dev/null 2>&1 || [ -d "$HOME/.config/labwc" ]; then
    log "Detected labwc — writing ~/.config/labwc/autostart"
    mkdir -p "$HOME/.config/labwc"
    AUTOSTART="$HOME/.config/labwc/autostart"
    touch "$AUTOSTART"
    grep -q 'pms-kiosk.sh' "$AUTOSTART" 2>/dev/null \
        || echo "$LAUNCHER &" >> "$AUTOSTART"
    wired=1
fi

# wayfire (alternative Wayland compositor)
if [ -f "$HOME/.config/wayfire.ini" ]; then
    log "Detected wayfire.ini — adding [autostart] entry"
    if ! grep -q 'pms_kiosk' "$HOME/.config/wayfire.ini"; then
        if ! grep -q '^\[autostart\]' "$HOME/.config/wayfire.ini"; then
            printf '\n[autostart]\n' >> "$HOME/.config/wayfire.ini"
        fi
        echo "pms_kiosk = $LAUNCHER" >> "$HOME/.config/wayfire.ini"
    fi
    wired=1
fi

# X11 / LXDE (older Pi OS or Lite + manual X)
if [ -d "$HOME/.config/lxsession" ] || [ "${XDG_SESSION_TYPE:-}" = "x11" ]; then
    LXDIR="$HOME/.config/lxsession/LXDE-pi"
    log "Writing X11/LXDE autostart at $LXDIR/autostart"
    mkdir -p "$LXDIR"
    touch "$LXDIR/autostart"
    grep -q 'pms-kiosk.sh' "$LXDIR/autostart" 2>/dev/null \
        || echo "@$LAUNCHER" >> "$LXDIR/autostart"
    wired=1
fi

if [ "$wired" -eq 0 ]; then
    warn "Could not detect the desktop session type."
    warn "Add this line to your compositor's autostart manually:"
    warn "    $LAUNCHER &"
fi

log "Kiosk setup complete. Reboot to launch the dashboard fullscreen:"
echo "    sudo reboot"
echo
log "To test now without rebooting:  $LAUNCHER"
