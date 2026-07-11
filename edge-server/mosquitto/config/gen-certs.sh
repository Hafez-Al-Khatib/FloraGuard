#!/usr/bin/env bash
# Generate self-signed CA and server certificates for Mosquitto + Nginx.
# Run from edge-server/mosquitto/certs/

set -euo pipefail

mkdir -p ../certs ../../nginx/certs
cd ../certs

CN="${1:-plant-hub.local}"
# Optional LAN IP baked into the server cert's SAN so clients that connect by
# IP (e.g. an Android phone that can't resolve plant-hub.local over mDNS) still
# validate. Pass as the 2nd arg or via PMS_HOST_IP.
EXTRA_IP="${2:-${PMS_HOST_IP:-}}"
DAYS=365

echo "Generating CA..."
openssl genrsa -aes256 -passout pass:plantmonitor -out ca.key 2048
openssl req -new -x509 -days 3650 -key ca.key -passin pass:plantmonitor -out ca.crt \
  -subj "/C=US/O=PlantMonitor/CN=PlantMonitor Root CA"

echo "Generating server certificate for CN=$CN..."
openssl genrsa -out server.key 2048
openssl req -new -key server.key -out server.csr -subj "/C=US/O=PlantMonitor/CN=$CN"

# subjectAltName — modern TLS clients (Android, Chrome, Dart's HttpClient)
# validate the SAN and ignore CN entirely. Without this a strict client rejects
# the cert even when the CA is trusted.
cat > server.ext <<EXT
subjectAltName = @alt_names
[alt_names]
DNS.1 = $CN
DNS.2 = localhost
IP.1 = 127.0.0.1
EXT
if [ -n "$EXTRA_IP" ]; then
  echo "IP.2 = $EXTRA_IP" >> server.ext
  echo "Adding IP SAN: $EXTRA_IP"
fi

openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out server.crt -days "$DAYS" -sha256 -passin pass:plantmonitor \
  -extfile server.ext

echo "Copying certs to Nginx..."
cp server.crt ../../nginx/certs/server.crt
cp server.key ../../nginx/certs/server.key

rm -f server.csr server.ext

echo "Done. CA cert: $(pwd)/ca.crt"
echo "Server cert: $(pwd)/server.crt"
echo "Remember to change the placeholder CA password in production!"
