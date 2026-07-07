/*
  Plant Monitoring System — Soil Node (Type A)
  Hardware: ESP32-S3 + HW-103 / HW-080 analog capacitive soil moisture sensors
  Transport: WiFi + MQTT

  Cycle (deep-sleep based, ~60 s interval):
    1. Boot / wake from deep sleep
    2. Read each sensor via ADC (analog)
    3. Connect WiFi
    4. Connect MQTT broker
    5. Publish JSON telemetry to  pms/telemetry/{node_id}
    6. Disconnect, enter deep sleep

  Wiring per sensor:
    VCC  → 3.3V pin on ESP32-S3
    GND  → GND
    AOUT → ADC1 GPIO (see SENSOR_PINS in secrets.h)

  NOTE: Use ADC1 pins only (GPIO 1–10 on ESP32-S3).
        ADC2 is shared with the WiFi radio and gives unreliable readings
        once WiFi is initialised.

  Calibration:
    1. Stick sensor in dry air  → note ADC value → set MOISTURE_DRY
    2. Submerge sensor in water → note ADC value → set MOISTURE_WET
    Typical ESP32-S3 values: dry ≈ 2800–3100, wet ≈ 1000–1400

  Credentials: copy src/secrets.h.example → src/secrets.h and fill values.
  secrets.h is gitignored; never commit it.
*/

#include <Arduino.h>
#include <WiFi.h>
#include <PubSubClient.h>
#include <ArduinoJson.h>
#include "secrets.h"

// ---------- Timing ----------
#define SLEEP_US        (60ULL * 1000ULL * 1000ULL)  // 60 s
#define WIFI_TIMEOUT_MS 10000

// ---------- ADC config ----------
// 12-bit ADC, 0–4095. Attenuation set to 11 dB → full 0–3.3 V range.
// Sensors read BEFORE WiFi starts — ADC2 is unusable during radio activity,
// ADC1 is fine throughout. Read 8 samples and average to reduce noise.
#define ADC_SAMPLES     8
#define ADC_ATTEN       ADC_11db   // full 3.3 V range

// Calibration — adjust after measuring your specific sensors in dry air and
// submerged in water. Capacitive sensors invert: dry = high ADC, wet = low.
#ifndef MOISTURE_DRY
  #define MOISTURE_DRY  2800   // ADC reading in dry air  (high = dry)
#endif
#ifndef MOISTURE_WET
  #define MOISTURE_WET  1000   // ADC reading in water    (low  = wet)
#endif

// ---------- RTC state (survives deep sleep) ----------
RTC_DATA_ATTR uint32_t boot_count = 0;

// ─────────────────────────────────────────────────────────────────────────────
static const char *reset_reason_str() {
    switch (esp_reset_reason()) {
        case ESP_RST_POWERON:   return "poweron";
        case ESP_RST_EXT:       return "ext";
        case ESP_RST_SW:        return "sw";
        case ESP_RST_PANIC:     return "panic";
        case ESP_RST_INT_WDT:   return "int_wdt";
        case ESP_RST_TASK_WDT:  return "task_wdt";
        case ESP_RST_WDT:       return "wdt";
        case ESP_RST_DEEPSLEEP: return "deepsleep";
        case ESP_RST_BROWNOUT:  return "brownout";
        case ESP_RST_SDIO:      return "sdio";
        default:                return "unknown";
    }
}

// ---------- Globals ----------
WiFiClient   wifi_client;
PubSubClient mqtt_client(wifi_client);

// ─────────────────────────────────────────────────────────────────────────────
// Analog moisture read
// Returns 0.0–100.0 % VWC, or -1.0 on error.
// Call BEFORE wifi_connect() — ADC is most accurate with radio off.
// ─────────────────────────────────────────────────────────────────────────────
float read_moisture_pct(uint8_t pin) {
    analogSetAttenuation(ADC_ATTEN);

    long sum = 0;
    for (int i = 0; i < ADC_SAMPLES; ++i) {
        sum += analogRead(pin);
        delay(5);
    }
    int raw = (int)(sum / ADC_SAMPLES);
    Serial.printf("[ADC] pin=%d raw=%d (dry_ref=%d wet_ref=%d)\n",
                  pin, raw, MOISTURE_DRY, MOISTURE_WET);

    // Map: MOISTURE_DRY → 0 %, MOISTURE_WET → 100 %
    // Clamp to valid range — readings outside calibration bounds are clamped,
    // not extrapolated, to avoid publishing impossible values.
    float pct = (float)(MOISTURE_DRY - raw) /
                (float)(MOISTURE_DRY - MOISTURE_WET) * 100.0f;
    return constrain(pct, 0.0f, 100.0f);
}

// ─────────────────────────────────────────────────────────────────────────────
// WiFi
// ─────────────────────────────────────────────────────────────────────────────
bool wifi_connect() {
    Serial.printf("[WiFi] Connecting to \"%s\"...\n", WIFI_SSID);
    WiFi.mode(WIFI_STA);
    WiFi.begin(WIFI_SSID, WIFI_PASS);

    unsigned long t0 = millis();
    while (WiFi.status() != WL_CONNECTED && millis() - t0 < WIFI_TIMEOUT_MS) {
        delay(250);
        Serial.print('.');
    }
    Serial.println();

    if (WiFi.status() != WL_CONNECTED) {
        Serial.println("[WiFi] Failed");
        return false;
    }
    Serial.printf("[WiFi] Connected — IP %s\n", WiFi.localIP().toString().c_str());
    return true;
}

// ─────────────────────────────────────────────────────────────────────────────
// MQTT
// ─────────────────────────────────────────────────────────────────────────────
bool mqtt_connect() {
    mqtt_client.setServer(MQTT_HOST, MQTT_PORT);
    mqtt_client.setKeepAlive(15);

    char client_id[64];
    snprintf(client_id, sizeof(client_id), "pms-soil-%s-%lu",
             SENSOR_NODE_IDS[0], boot_count);

    Serial.printf("[MQTT] Connecting as %s...\n", client_id);
    bool ok = mqtt_client.connect(client_id, MQTT_USER, MQTT_PASS);
    if (!ok)
        Serial.printf("[MQTT] Failed, state=%d\n", mqtt_client.state());
    return ok;
}

// ─────────────────────────────────────────────────────────────────────────────
// Publish telemetry for one sensor, with retry.
//
// retain=true: the broker stores the last message per topic. If the FastAPI
// MQTT subscriber restarts while the ESP32 is sleeping it immediately receives
// the most recent reading on reconnect, so the dashboard never shows stale "--"
// values just because the backend bounced.
//
// Up to PUBLISH_RETRIES attempts with a short back-off between each. A failed
// publish is logged clearly rather than silently dropped.
// ─────────────────────────────────────────────────────────────────────────────
#define PUBLISH_RETRIES 3
#define PUBLISH_RETRY_MS 200

bool publish_telemetry(const char *node_id, float moisture,
                       uint8_t battery_pct, bool sensor_ok) {
    JsonDocument doc;
    doc["node_id"]     = node_id;
    doc["seq"]         = boot_count;
    doc["sensor_ok"]   = sensor_ok;

    if (sensor_ok)
        doc["moisture"] = round(moisture * 10) / 10.0;  // 1 d.p.

    doc["battery_pct"]  = battery_pct;
    doc["reset_reason"] = reset_reason_str();
    doc["free_heap"]    = ESP.getFreeHeap();

    char payload[200];
    size_t len = serializeJson(doc, payload, sizeof(payload));

    char topic[96];
    snprintf(topic, sizeof(topic), "pms/telemetry/%s", node_id);

    for (int attempt = 1; attempt <= PUBLISH_RETRIES; ++attempt) {
        // loop() must be called before publish on retry — it processes the TCP
        // layer and can recover from a transient broker-side backpressure event.
        mqtt_client.loop();

        bool ok = mqtt_client.publish(topic, (const uint8_t *)payload, len,
                                      /*retain=*/true);
        Serial.printf("[MQTT] publish attempt %d/%d → %s (%s)\n",
                      attempt, PUBLISH_RETRIES, topic, ok ? "ok" : "FAIL");
        if (ok) return true;

        if (attempt < PUBLISH_RETRIES)
            delay(PUBLISH_RETRY_MS * attempt);  // 200 ms, 400 ms back-off
    }

    Serial.printf("[WARN] publish failed after %d attempts: %s\n",
                  PUBLISH_RETRIES, topic);
    return false;
}

// ─────────────────────────────────────────────────────────────────────────────
// Battery ADC (optional — wire a 1:1 voltage divider to BATTERY_ADC_PIN)
// ─────────────────────────────────────────────────────────────────────────────
static uint8_t read_battery_pct() {
#ifdef BATTERY_ADC_PIN
    int raw   = analogRead(BATTERY_ADC_PIN);
    float v   = raw / 4095.0f * 3.3f * 2.0f;
    float pct = (v - 3.0f) / (4.2f - 3.0f) * 100.0f;
    return (uint8_t)constrain(pct, 0, 100);
#else
    return 100;
#endif
}

// ─────────────────────────────────────────────────────────────────────────────
// Entry point
// ─────────────────────────────────────────────────────────────────────────────
void setup() {
    Serial.begin(115200);
    delay(100);
    Serial.printf("\n=== PMS Soil Node boot #%lu ===\n", boot_count);

    // ── 1. Read sensors BEFORE WiFi (ADC most stable with radio off) ──────────
    float moisture_readings[SENSOR_COUNT];
    for (int i = 0; i < SENSOR_COUNT; ++i) {
        moisture_readings[i] = read_moisture_pct(SENSOR_PINS[i]);
        Serial.printf("[SENSOR] %s → %.1f%%\n",
                      SENSOR_NODE_IDS[i], moisture_readings[i]);
    }

    uint8_t battery_pct = read_battery_pct();

    // ── 2. Network ────────────────────────────────────────────────────────────
    if (!wifi_connect() || !mqtt_connect()) {
        Serial.println("[WARN] Network unavailable — will retry next cycle");
        esp_sleep_enable_timer_wakeup(SLEEP_US);
        esp_deep_sleep_start();
    }

    // ── 3. Cold-boot hello: register nodes before first reading ──────────────
    if (esp_reset_reason() != ESP_RST_DEEPSLEEP) {
        for (int i = 0; i < SENSOR_COUNT; ++i) {
            JsonDocument hello;
            hello["node_id"]      = SENSOR_NODE_IDS[i];
            hello["hello"]        = true;
            hello["kind"]         = "soil";
            hello["reset_reason"] = reset_reason_str();
            hello["free_heap"]    = ESP.getFreeHeap();

            char payload[160];
            size_t len = serializeJson(hello, payload, sizeof(payload));
            char topic[96];
            snprintf(topic, sizeof(topic), "pms/telemetry/%s", SENSOR_NODE_IDS[i]);
            mqtt_client.publish(topic, (const uint8_t *)payload, len, false);
            Serial.printf("[MQTT] hello → %s\n", topic);
            delay(25);
        }
    }

    // ── 4. Publish telemetry ──────────────────────────────────────────────────
    int failed = 0;
    for (int i = 0; i < SENSOR_COUNT; ++i) {
        bool ok = publish_telemetry(SENSOR_NODE_IDS[i],
                                    moisture_readings[i],
                                    battery_pct,
                                    /*sensor_ok=*/true);
        if (!ok) ++failed;
        delay(50);
    }
    if (failed)
        Serial.printf("[WARN] %d/%d publishes failed this cycle\n",
                      failed, SENSOR_COUNT);

    // ── 5. Drain buffer, sleep ────────────────────────────────────────────────
    unsigned long deadline = millis() + 500;
    while (millis() < deadline && mqtt_client.connected())
        mqtt_client.loop();

    ++boot_count;
    mqtt_client.disconnect();
    WiFi.disconnect(true);

    Serial.printf("[INFO] Sleeping 60 s\n");
    esp_sleep_enable_timer_wakeup(SLEEP_US);
    esp_deep_sleep_start();
}

void loop() {
    // Never reached — deep sleep restarts from setup()
}
