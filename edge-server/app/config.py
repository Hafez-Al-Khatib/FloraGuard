"""Application settings loaded from environment variables."""
from functools import lru_cache
from pathlib import Path

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


# Auto-load class labels from the exported PlantVillage label file if it exists.
_DEFAULT_MODEL_PATH = Path("models/plantvillage_resnet18_15cls_int8.onnx")
_DEFAULT_LABELS_PATH = _DEFAULT_MODEL_PATH.with_name("plantvillage_labels.json")
_DEFAULT_LABELS = ["Healthy"]
if _DEFAULT_LABELS_PATH.exists():
    import json as _json

    with open(_DEFAULT_LABELS_PATH) as _f:
        _DEFAULT_LABELS = _json.load(_f)


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
        protected_namespaces=("settings_",),
    )

    # Redis
    redis_host: str = "localhost"
    redis_port: int = 6379
    redis_password: str = ""
    redis_db: int = 0

    # MQTT
    mqtt_host: str = "localhost"
    mqtt_port: int = 8883
    mqtt_username: str = ""
    mqtt_password: str = ""
    mqtt_ca_cert: str | None = None

    # InfluxDB
    influxdb_url: str = "http://localhost:8086"
    influxdb_token: str = ""
    influxdb_org: str = "plantmonitor"
    influxdb_bucket: str = "telemetry"

    # Chat provider — cloud API; the rest of the system runs fully offline.
    # Supported values: "gemini" (free tier, good for testing) | "anthropic" (production)
    chat_provider: str = "gemini"
    chat_timeout: float = 60.0
    # Gemini (Google AI Studio — free tier: https://aistudio.google.com/apikey)
    gemini_api_key: str = ""
    # gemini-2.5-flash is the current default in AI Studio (GA). If a key was
    # provisioned recently it may not have 2.0 access. Override via env if needed.
    gemini_model: str = "gemini-2.5-flash"
    # Anthropic Claude (paid, ~$0.25/M tokens with Haiku)
    anthropic_api_key: str = ""
    anthropic_model: str = "claude-haiku-4-5-20251001"

    # API Security
    api_auth_token: str = "change-me-in-production"
    # CORS: explicit allowlist of browser origins permitted to call the API.
    # Stored as a raw comma-separated string (env: CORS_ALLOW_ORIGINS) to avoid
    # pydantic-settings JSON-decoding a list env value, then exposed as a parsed
    # list via the property below. A wildcard "*" is intentionally not allowed.
    cors_allow_origins_raw: str = Field(
        default="https://plant-hub.local",
        validation_alias="CORS_ALLOW_ORIGINS",
    )

    @property
    def cors_allow_origins(self) -> list[str]:
        return [o.strip() for o in self.cors_allow_origins_raw.split(",") if o.strip()]

    # Automation / closed-loop control
    control_scan_interval: float = 15.0          # seconds between control evaluations
    automation_mode_default: str = "advisory"    # "advisory" (log only) | "auto" (actuate)
    irrigation_moisture_setpoint: float = 30.0   # % VWC: irrigate when below this
    irrigation_moisture_target: float = 55.0     # % VWC: stop irrigating at/above this
    actuator_max_run_seconds: int = 300          # safety: hard cap on a single run
    actuator_cooldown_seconds: int = 300         # safety: min idle time between runs
    actuator_daily_cap_seconds: int = 3600       # safety: max total runtime per day
    sensor_sanity_max_age_seconds: int = 600     # refuse to actuate on stale readings

    # Alerting
    alert_scan_interval: float = 30.0      # seconds between background scans
    node_offline_seconds: int = 180        # last-seen age that marks a node offline
    moisture_low_threshold: float = 20.0   # % VWC below this raises a dry-soil alert
    battery_low_threshold: float = 20.0    # % below this raises a low-battery alert
    disease_confidence_threshold: float = 0.70  # detection confidence that raises an alert
    alert_webhook_url: str = ""            # optional: POST alerts here (config-gated)

    # Upload / inference
    max_image_size: int = 2 * 1024 * 1024  # 2 MB
    allowed_image_types: frozenset[str] = frozenset({"image/jpeg", "image/png", "image/webp"})
    model_path: Path = _DEFAULT_MODEL_PATH
    class_labels: list[str] = _DEFAULT_LABELS

    # Logging
    log_level: str = "INFO"


@lru_cache
def get_settings() -> Settings:
    return Settings()
