#!/usr/bin/env bash
#
# Plant Monitoring System — NVIDIA Jetson Orin Nano bootstrap.
#
# Run ONCE on a fresh JetPack 6 (Ubuntu 22.04, L4T r36.x) install to:
#   1. Verify Docker + the NVIDIA container runtime (ships with JetPack)
#   2. Make `nvidia` the default Docker runtime (so containers see the GPU)
#   3. Generate TLS certs (if missing) + create .env
#   4. Build the GPU-accelerated stack (api uses the Jetson ONNX Runtime image)
#   5. Install + enable the systemd auto-start service
#
# Usage (from the repo root on the Jetson):
#   chmod +x deploy/jetson-setup.sh
#   ./deploy/jetson-setup.sh
#
# IMPORTANT: the GPU api image base in edge-server/app/Dockerfile.jetson must
# match your JetPack/L4T version. Check `cat /etc/nv_tegra_release` and set the
# matching tag (see comments in that Dockerfile). GPU inference can only be
# verified on the device itself.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
EDGE_DIR="$REPO_ROOT/edge-server"
COMPOSE="docker-compose.yml -f docker-compose.jetson.yml"

log()  { printf '\033[1;32m[jetson]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

[ -d "$EDGE_DIR" ] || die "edge-server/ not found — run from the repo checkout."

# ── 1. Docker + NVIDIA runtime (preinstalled on JetPack) ──────────────────────
command -v docker >/dev/null 2>&1 || die "Docker not found. Flash JetPack 6, which includes Docker + nvidia-container-runtime."
if ! docker info 2>/dev/null | grep -qi nvidia; then
    warn "NVIDIA Docker runtime not detected; GPU inference will fall back to CPU."
fi

# ── 2. Make nvidia the default runtime so the GPU is visible in compose ────────
DAEMON=/etc/docker/daemon.json
if ! grep -q '"default-runtime"\s*:\s*"nvidia"' "$DAEMON" 2>/dev/null; then
    log "Setting nvidia as the default Docker runtime..."
    sudo mkdir -p /etc/docker
    if [ -f "$DAEMON" ] && command -v jq >/dev/null 2>&1; then
        sudo jq '. + {"default-runtime":"nvidia"}' "$DAEMON" | sudo tee "$DAEMON.tmp" >/dev/null
        sudo mv "$DAEMON.tmp" "$DAEMON"
    else
        printf '{\n  "default-runtime": "nvidia",\n  "runtimes": {\n    "nvidia": {\n      "path": "nvidia-container-runtime",\n      "runtimeArgs": []\n    }\n  }\n}\n' | sudo tee "$DAEMON" >/dev/null
    fi
    sudo systemctl restart docker
fi

# ── 3. Env + TLS ──────────────────────────────────────────────────────────────
if [ ! -f "$EDGE_DIR/.env" ]; then
    log "Creating edge-server/.env from template (set real secrets before start!)..."
    cp "$EDGE_DIR/app/example.env" "$EDGE_DIR/.env"
fi
if [ ! -f "$EDGE_DIR/nginx/certs/server.crt" ]; then
    log "Generating self-signed TLS certs..."
    ( cd "$EDGE_DIR/mosquitto/config" && bash gen-certs.sh "${PMS_HOSTNAME:-plant-hub.local}" )
fi

# ── 4. Build the GPU stack ────────────────────────────────────────────────────
log "Building containers (api uses the Jetson ONNX Runtime base — first build is long)..."
( cd "$EDGE_DIR" && sudo docker compose -f $COMPOSE build )

# ── 5. systemd auto-start (GPU compose overlay) ───────────────────────────────
log "Installing systemd service..."
sed -e "s|__EDGE_DIR__|$EDGE_DIR|g" \
    -e "s|docker compose up -d|docker compose -f $COMPOSE up -d|g" \
    -e "s|docker compose down|docker compose -f $COMPOSE down|g" \
    "$SCRIPT_DIR/pms-stack.service" \
    | sudo tee /etc/systemd/system/pms-stack.service >/dev/null
sudo systemctl daemon-reload
sudo systemctl enable pms-stack.service

log "Bootstrap complete (built + enabled, NOT started — set secrets first)."
echo
warn "Next:"
echo "  1. nano $EDGE_DIR/.env        # secrets + GEMINI_API_KEY"
echo "  2. sudo systemctl start pms-stack"
echo "  3. Verify GPU EP: docker compose -f $EDGE_DIR/docker-compose.yml -f $EDGE_DIR/docker-compose.jetson.yml logs api | grep onnx_session_ready"
echo "     -> expect provider=CUDAExecutionProvider or TensorrtExecutionProvider"
