/*
  Plant Monitoring System — Camera Node (Type B)
  Hardware: AI-Thinker ESP32-CAM (classic ESP32) + OV2640
  (Pin map below is the AI-Thinker pinout; board = esp32cam in platformio.ini.)

  Cycle (deep-sleep based, ~60 s interval):
    1. Wake, initialise camera
    2. Capture frame, run blur pre-filter
    3. If sharp enough: connect WiFi, POST raw JPEG to FastAPI, disconnect
    4. Deep sleep

  Credentials: copy src/secrets.h.example → src/secrets.h and fill values.
  secrets.h is gitignored; never commit it.
*/

#include <Arduino.h>
#include <WiFi.h>
#include <HTTPClient.h>
#include <esp_camera.h>
#include "secrets.h"

// ─────────────────────────────────────────────────────────────────────────────
// Camera pin mapping — AI-Thinker OV2640 module
// ─────────────────────────────────────────────────────────────────────────────
#define PWDN_GPIO_NUM   32
#define RESET_GPIO_NUM  -1
#define XCLK_GPIO_NUM    0
#define SIOD_GPIO_NUM   26
#define SIOC_GPIO_NUM   27
#define Y9_GPIO_NUM     35
#define Y8_GPIO_NUM     34
#define Y7_GPIO_NUM     39
#define Y6_GPIO_NUM     36
#define Y5_GPIO_NUM     21
#define Y4_GPIO_NUM     19
#define Y3_GPIO_NUM     18
#define Y2_GPIO_NUM      5
#define VSYNC_GPIO_NUM  25
#define HREF_GPIO_NUM   23
#define PCLK_GPIO_NUM   22

// ─────────────────────────────────────────────────────────────────────────────
// Tuning constants
// ─────────────────────────────────────────────────────────────────────────────
#define CAPTURE_INTERVAL_US   (60ULL * 1000ULL * 1000ULL)  // 60 s
#define WIFI_TIMEOUT_MS       10000
#define HTTP_TIMEOUT_MS       15000
#define UPLOAD_RETRY_COUNT    2        // retry once on HTTP error before giving up
// 0.0 = upload every frame (use this to prove the pipeline on first flash).
// Raise it (e.g. 80.0) afterwards to drop blurry/uniform frames and save bandwidth.
#define BLUR_THRESHOLD        0.0f     // byte-variance proxy; raise after first run

// ─────────────────────────────────────────────────────────────────────────────
// Camera init
// ─────────────────────────────────────────────────────────────────────────────
bool init_camera() {
    camera_config_t cfg = {};
    cfg.ledc_channel  = LEDC_CHANNEL_0;
    cfg.ledc_timer    = LEDC_TIMER_0;
    cfg.pin_pwdn      = PWDN_GPIO_NUM;
    cfg.pin_reset     = RESET_GPIO_NUM;
    cfg.pin_xclk      = XCLK_GPIO_NUM;
    cfg.pin_sccb_sda  = SIOD_GPIO_NUM;
    cfg.pin_sccb_scl  = SIOC_GPIO_NUM;
    cfg.pin_d7        = Y9_GPIO_NUM;
    cfg.pin_d6        = Y8_GPIO_NUM;
    cfg.pin_d5        = Y7_GPIO_NUM;
    cfg.pin_d4        = Y6_GPIO_NUM;
    cfg.pin_d3        = Y5_GPIO_NUM;
    cfg.pin_d2        = Y4_GPIO_NUM;
    cfg.pin_d1        = Y3_GPIO_NUM;
    cfg.pin_d0        = Y2_GPIO_NUM;
    cfg.pin_vsync     = VSYNC_GPIO_NUM;
    cfg.pin_href      = HREF_GPIO_NUM;
    cfg.pin_pclk      = PCLK_GPIO_NUM;
    cfg.xclk_freq_hz  = 20000000;
    cfg.pixel_format  = PIXFORMAT_JPEG;
    cfg.frame_size    = FRAMESIZE_VGA;   // 640×480; good balance of detail vs. transfer time
    cfg.jpeg_quality  = 12;              // 0–63, lower = better quality
    cfg.fb_count      = 1;

    esp_err_t err = esp_camera_init(&cfg);
    if (err != ESP_OK) {
        Serial.printf("[CAM] Init failed: 0x%x\n", err);
        return false;
    }
    return true;
}

// ─────────────────────────────────────────────────────────────────────────────
// Blur / quality pre-filter
// Uses byte-entropy of the JPEG buffer as a proxy for detail.
// Frames that are out-of-focus or pointing at uniform surfaces score low and
// are dropped, saving upload bandwidth.
// ─────────────────────────────────────────────────────────────────────────────
float frame_quality(const camera_fb_t *fb) {
    if (!fb || fb->len < 256) return 0.0f;
    const size_t step = fb->len / 256;
    long sum = 0, sum_sq = 0;
    for (size_t i = 0; i < fb->len; i += step) {
        uint8_t v = fb->buf[i];
        sum    += v;
        sum_sq += (long)v * v;
    }
    size_t n = fb->len / step;
    float mean = (float)sum / n;
    return (float)sum_sq / n - mean * mean;   // variance as quality proxy
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
// Wake-up hello — POST /api/v1/node/{node_id}/hello
// Idempotent pairing call so the dashboard card materialises even before the
// first frame is uploaded (which can take a while on a marginal link).
// Sent only on cold boots (poweron/panic/brownout); scheduled deep-sleep
// wakes skip it as redundant.
// ─────────────────────────────────────────────────────────────────────────────
void send_hello() {
    HTTPClient http;
    String url = String(API_BASE_URL) + "/node/" + NODE_ID + "/hello";
    http.begin(url);
    http.addHeader("Authorization", "Bearer " + String(API_TOKEN));
    http.addHeader("Content-Type",  "application/json");
    http.setTimeout(HTTP_TIMEOUT_MS);

    String body =
        String("{\"kind\":\"camera\",\"firmware_version\":\"1.0\",\"reset_reason\":\"") +
        ([](){
            switch (esp_reset_reason()) {
                case ESP_RST_POWERON:   return "poweron";
                case ESP_RST_PANIC:     return "panic";
                case ESP_RST_BROWNOUT:  return "brownout";
                case ESP_RST_TASK_WDT:  return "task_wdt";
                case ESP_RST_DEEPSLEEP: return "deepsleep";
                default:                return "unknown";
            }
        }()) + "\"}";

    int code = http.POST(body);
    Serial.printf("[HTTP] hello — status %d\n", code);
    http.end();
}

// ─────────────────────────────────────────────────────────────────────────────
// Upload JPEG to FastAPI  POST /api/v1/node/{node_id}/upload-frame
// The endpoint accepts a raw binary body with Content-Type: image/jpeg.
// Returns true if the server acknowledged with HTTP 200.
// ─────────────────────────────────────────────────────────────────────────────
bool upload_frame(const camera_fb_t *fb) {
    HTTPClient http;
    String url = String(API_BASE_URL) + "/node/" + NODE_ID + "/upload-frame";

    for (int attempt = 1; attempt <= UPLOAD_RETRY_COUNT; ++attempt) {
        http.begin(url);
        http.addHeader("Authorization", "Bearer " + String(API_TOKEN));
        http.addHeader("Content-Type",  "image/jpeg");
        // NOTE: do NOT add Content-Length manually — HTTPClient::POST(buf,len)
        // sets it, and a duplicate header makes uvicorn/h11 reject the request.
        http.setTimeout(HTTP_TIMEOUT_MS);

        int code = http.POST(const_cast<uint8_t *>(fb->buf), fb->len);
        Serial.printf("[HTTP] attempt %d/%d — status %d\n", attempt, UPLOAD_RETRY_COUNT, code);
        http.end();

        if (code == 200) return true;

        // Brief back-off before retry
        if (attempt < UPLOAD_RETRY_COUNT)
            delay(1000 * attempt);
    }
    return false;
}

// ─────────────────────────────────────────────────────────────────────────────
// Entry point
// ─────────────────────────────────────────────────────────────────────────────
void setup() {
    Serial.begin(115200);
    delay(100);
    Serial.printf("\n=== PMS Camera Node [%s] boot ===\n", NODE_ID);

    auto sleep_now = []() {
        esp_sleep_enable_timer_wakeup(CAPTURE_INTERVAL_US);
        esp_deep_sleep_start();
    };

    if (!init_camera()) {
        Serial.println("[CAM] Init failed — skipping cycle");
        sleep_now();
        return;  // deep sleep never returns; explicit for safety
    }

    camera_fb_t *fb = esp_camera_fb_get();
    if (!fb) {
        Serial.println("[CAM] Capture failed — skipping cycle");
        esp_camera_deinit();
        sleep_now();
        return;
    }

    float quality = frame_quality(fb);
    Serial.printf("[CAM] Frame size=%u  quality=%.1f  threshold=%.1f\n",
                  fb->len, quality, (float)BLUR_THRESHOLD);

    bool uploaded = false;
    if (quality >= BLUR_THRESHOLD) {
        if (wifi_connect()) {
            // Cold boot? Pair first so the card shows up even if the frame
            // upload fails on a marginal link.
            if (esp_reset_reason() != ESP_RST_DEEPSLEEP) {
                send_hello();
            }
            uploaded = upload_frame(fb);
            WiFi.disconnect(true);
        }
    } else {
        Serial.println("[CAM] Frame rejected (blurry / low detail) — not uploading");
    }

    esp_camera_fb_return(fb);
    esp_camera_deinit();

    Serial.printf("[INFO] uploaded=%s — sleeping\n", uploaded ? "true" : "false");
    sleep_now();
}

void loop() {
    // Not reached — deep sleep restarts from setup()
}
