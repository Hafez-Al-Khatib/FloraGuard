"""LOCAL DEV launcher — runs the API with an in-memory Redis, no Docker needed.

Why this exists: the full stack normally runs under Docker (Redis, Mosquitto,
InfluxDB, API). For quickly testing the vision pipeline on a laptop without
Docker, this script swaps Redis for an in-process `fakeredis` and starts the
same FastAPI app. InfluxDB and MQTT simply fail gracefully (telemetry
persistence is skipped); the camera upload/analyze path needs only Redis.

NOT for production. Run from edge-server/app/:
    .venv\\Scripts\\python.exe dev_server.py
"""
from __future__ import annotations

import os
import pathlib

# ── 1. Load edge-server/.env (one level up) so the real API token, Gemini key,
#       and CORS origins are used — mirrors docker-compose.dev.yml. ────────────
_ENV = pathlib.Path(__file__).resolve().parent.parent / ".env"
if _ENV.exists():
    for _line in _ENV.read_text(encoding="utf-8").splitlines():
        _line = _line.strip()
        if not _line or _line.startswith("#") or "=" not in _line:
            continue
        _k, _, _v = _line.partition("=")
        os.environ.setdefault(_k.strip(), _v.strip())

os.environ.setdefault("LOG_LEVEL", "INFO")

# ── 2. Replace Redis with an in-memory fake. A single shared FakeServer backs
#       both the text and binary clients so the JPEG written by /upload-frame
#       is visible to /analyze. ───────────────────────────────────────────────
import fakeredis.aioredis as _fake  # noqa: E402

import services  # noqa: E402

_SERVER = _fake.FakeServer()


def _text_redis(self):
    if self._r is None:
        self._r = _fake.FakeRedis(server=_SERVER, decode_responses=True)
    return self._r


def _binary_redis(self):
    if self._rb is None:
        self._rb = _fake.FakeRedis(server=_SERVER, decode_responses=False)
    return self._rb


services.Cache._text_redis = _text_redis
services.Cache._binary_redis = _binary_redis

# ── 3. Import the app (after env + patches are in place) and serve. ───────────
import uvicorn  # noqa: E402

from main import app  # noqa: E402


if __name__ == "__main__":
    token = os.environ.get("API_AUTH_TOKEN", "change-me-in-production")
    print("=" * 64)
    print("  PMS dev server  —  in-memory Redis, no Docker")
    print("  API:   http://localhost:8000")
    print(f"  Token: {token}")
    print("  Test:  python classify.py <image-url-or-path>")
    print("=" * 64)
    uvicorn.run(app, host="0.0.0.0", port=8000, log_level="info")
