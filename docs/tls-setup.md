# TLS Certificate Setup

This project uses mutual TLS between the MQTT broker and field nodes, and HTTPS for the dashboard and API. For local development and on-prem farm deployments you can use a self-signed CA.

## Generate a self-signed CA and server certificates

Run the following from the `edge-server/` directory on a machine with OpenSSL installed:

```bash
cd mosquitto/certs

# 1. Create CA
openssl genrsa -aes256 -out ca.key 2048
openssl req -new -x509 -days 3650 -key ca.key -out ca.crt \
  -subj "/C=US/O=PlantMonitor/CN=PlantMonitor Root CA"

# 2. Create MQTT broker certificate
openssl genrsa -out server.key 2048
openssl req -new -key server.key -out server.csr \
  -subj "/C=US/O=PlantMonitor/CN=plant-hub.local"
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out server.crt -days 365 -sha256

# 3. Copy server cert/key for Nginx
cp server.crt ../../nginx/certs/server.crt
cp server.key ../../nginx/certs/server.key

# 4. Create a client certificate for the soil node (optional, for mTLS)
openssl genrsa -out node-01.key 2048
openssl req -new -key node-01.key -out node-01.csr \
  -subj "/C=US/O=PlantMonitor/CN=node-01"
openssl x509 -req -in node-01.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out node-01.crt -days 365 -sha256
```

## Trust the CA on client devices

- **Flutter web dashboard browsers:** Accept the self-signed certificate exception, or install `ca.crt` into the OS trust store.
- **ESP32 nodes:** Embed `ca.crt` as a PEM constant and configure `WiFiClientSecure.setCACert(...)`.
- **Production:** Replace the self-signed CA with a customer-managed internal CA or certificates from a trusted public CA.

## Mosquitto mTLS (optional enhancement)

To require client certificates from field nodes:

```text
listener 8883
...
require_certificate true
use_identity_as_username true
tls_version tlsv1.2
```

This prevents rogue devices from joining the MQTT broker even if they obtain the Wi-Fi password.
