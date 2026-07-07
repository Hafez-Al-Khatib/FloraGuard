"""Test fixtures and environment overrides."""
import os

# Ensure a predictable auth token for tests regardless of .env contents.
os.environ.setdefault("API_AUTH_TOKEN", "pms-local-dev-token-change-in-production")
os.environ.setdefault("LOG_LEVEL", "DEBUG")
os.environ.setdefault("REDIS_PASSWORD", "")
os.environ.setdefault("INFLUXDB_TOKEN", "test-token")
