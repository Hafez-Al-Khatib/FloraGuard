#!/usr/bin/env bash
# Generate self-signed CA and server certificates for Mosquitto + Nginx.
# Run from edge-server/mosquitto/certs/

set -euo pipefail

mkdir -p ../certs ../../nginx/certs
cd ../certs

CN="${1:-plant-hub.local}"
DAYS=365

echo "Generating CA..."
openssl genrsa -aes256 -passout pass:plantmonitor -out ca.key 2048
openssl req -new -x509 -days 3650 -key ca.key -passin pass:plantmonitor -out ca.crt \
  -subj "/C=US/O=PlantMonitor/CN=PlantMonitor Root CA"

echo "Generating server certificate for CN=$CN..."
openssl genrsa -out server.key 2048
openssl req -new -key server.key -out server.csr -subj "/C=US/O=PlantMonitor/CN=$CN"
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out server.crt -days "$DAYS" -sha256 -passin pass:plantmonitor

echo "Copying certs to Nginx..."
cp server.crt ../../nginx/certs/server.crt
cp server.key ../../nginx/certs/server.key

rm -f server.csr

echo "Done. CA cert: $(pwd)/ca.crt"
echo "Server cert: $(pwd)/server.crt"
echo "Remember to change the placeholder CA password in production!"
