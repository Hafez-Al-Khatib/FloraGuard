#!/usr/bin/env bash
# Generate self-signed TLS certificate for local development.
# NOT suitable for production — use a real CA (Let's Encrypt, etc.) there.
set -euo pipefail

CERT_DIR="$(cd "$(dirname "$0")" && pwd)/certs"
mkdir -p "$CERT_DIR"

openssl req -x509 -newkey rsa:4096 \
  -keyout "$CERT_DIR/server.key" \
  -out    "$CERT_DIR/server.crt" \
  -sha256 -days 365 -nodes \
  -subj "/C=US/ST=Dev/L=Dev/O=PlantMonitorSystem/CN=plant-hub.local" \
  -addext "subjectAltName=DNS:plant-hub.local,DNS:localhost,IP:127.0.0.1"

chmod 600 "$CERT_DIR/server.key"

echo "Certificates written to $CERT_DIR/"
echo "  server.crt  — import into your OS/browser trust store to avoid warnings"
echo "  server.key  — keep private, never commit"
