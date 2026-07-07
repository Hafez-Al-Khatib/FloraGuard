# Session Handoff — Frontend Overhaul + Live Wiring

_Last updated: 2026-06-07 (overnight autonomous session)_

## TL;DR
The Flutter dashboard was redesigned ("Premium Glass-Nature") and wired to the
backend, which gained read endpoints. The full chain was validated live against
the Docker stack and screenshotted with real telemetry. All tests green:
**backend 23 passed, Flutter analyze clean, 1 widget test passed, web build OK.**

## What changed this session

### Backend (`edge-server/app/`)
- **New read endpoints** (`routes.py`):
  - `GET /api/v1/nodes` → `{"nodes": [...]}` (distinct nodes with cached telemetry)
  - `GET /api/v1/node/{id}/telemetry` → latest cached values, normalizes the
    cache `temp` key to `temperature` for the client.
- `services.py` → `Cache.list_nodes()` (SCAN-based node discovery).
- `config.py` → CORS allowlist as `cors_allow_origins_raw` (env `CORS_ALLOW_ORIGINS`,
  comma-separated) exposed via a `cors_allow_origins` property. **Do not** turn this
  back into a `list[str]` env field — pydantic-settings JSON-decodes list envs and
  crashes on a comma string (fixed this session).
- `docker-compose.dev.yml` / `docker-compose.yml` → now pass `CORS_ALLOW_ORIGINS`
  into the `api` container (previously missing → browsers were blocked by CORS).
- Tests: `test_api.py` (+nodes/+telemetry), new `test_config.py` (CORS parsing).

### Frontend (`dashboard/lib/`)
- `theme/app_theme.dart` — design tokens (palette, type scale, spacing), dark theme.
- `widgets/glass.dart` — `GlassCard` (real `BackdropFilter` blur + sheen + sharp
  shadow + sage border), `TechnicalDivider`, `StatusChip`, `MicroBar`,
  `LiveIndicator`, `NatureBackground`, `HealthState` enum.
- `widgets/telemetry_card.dart` — data-dense node card with status-colored states.
- `screens/login_screen.dart` — glass console + **kiosk deep-link**
  (`?hub=<url>&token=<tok>` prefills and auto-connects).
- `screens/dashboard_screen.dart` — header, responsive node grid, agronomist chat
  with **node selector** (bound to `/nodes`), streaming token append.
- `services/api_service.dart` — `fetchNodes` / `fetchTelemetry` / real
  `fetchLatestTelemetry` (mock removed).
- `main.dart` theme applied; `test/widget_test.dart` real login smoke test.

## How to reproduce the live run
```bash
# 1. backend (from edge-server/). NOTE: omni-sense project holds host ports
#    6379 (redis) and 1883 (mqtt). Stop it, or unpublish those ports, first.
docker compose -f docker-compose.dev.yml up -d redis influxdb api
# 2. seed telemetry (token = pms-local-dev-token-change-in-production)
curl -X POST localhost:8000/api/v1/telemetry -H "Authorization: Bearer <tok>" \
  -H "Content-Type: application/json" \
  -d '{"node_id":"soil-greenhouse-a","moisture":58.4,"temperature":24.8,"ec":1.3,"battery_pct":92}'
# 3. flutter web -> served on :8080 (CORS already allows it)
cd ../dashboard && flutter build web --no-tree-shake-icons
python -m http.server 8080 --bind 127.0.0.1 --directory build/web
# 4. open: http://localhost:8080/?hub=http://localhost:8000&token=<tok>
```
A preview launch config exists at `.claude/launch.json` (absolute path — local only).

## Docker packaging (completed this session)

- **`dashboard/Dockerfile`** — multi-stage Flutter build (ghcr.io/cirruslabs/flutter:stable)
  then nginx:alpine static serve. `dashboard/docker.nginx.conf` handles SPA routing.
- **`nginx/nginx.conf`** updated: `location /` now proxies to `dashboard:80` instead of
  bind-mounting the host Flutter build. No host Flutter SDK required for production deploy.
- **`edge-server/nginx/gen-dev-certs.sh`** — run once to generate self-signed TLS certs.
- **Redis ACL removed** — `--aclfile` dropped from prod Redis command (file didn't exist,
  would crash the container). `--requirepass` is sufficient; add ACLs later if needed.
- **Ollama removed entirely** — replaced with cloud chat provider (see below).
- **API Dockerfile** — non-root `pms` user added; `.dockerignore` excludes tests, `.env`.
- Both compose files now have a `dashboard` service; dev exposes it on `:8080`.

## Chat provider (completed this session)

Ollama + local `gemma3:1b` was replaced with a configurable cloud API:

| Env var | Default | Notes |
|---|---|---|
| `CHAT_PROVIDER` | `gemini` | `"gemini"` or `"anthropic"` |
| `GEMINI_API_KEY` | _(empty)_ | Free key at aistudio.google.com/apikey |
| `GEMINI_MODEL` | `gemini-2.0-flash` | Free tier available |
| `ANTHROPIC_API_KEY` | _(empty)_ | Paid; Haiku ≈ $0.25/M tokens |
| `ANTHROPIC_MODEL` | `claude-haiku-4-5-20251001` | Cheapest Claude |

Chat streams via `httpx` directly (no new SDK dependency). All other services
(Redis, InfluxDB, ONNX inference) remain fully offline.

If the API key is empty, the chat endpoint returns a clear error string instead
of crashing the server — the rest of the dashboard keeps working.

## Known follow-ups / not yet done
- **Chat end-to-end visual test** — set `GEMINI_API_KEY` in `.env` and open the
  dashboard to verify streaming tokens appear in the chat panel.
- **Wide-layout screenshot** not captured (preview viewport was < 900px, narrow layout).
- **TLS certs** — run `bash edge-server/nginx/gen-dev-certs.sh` before first `docker
  compose up` (prod). For production: replace with a real CA cert.
- **Token in URL** for kiosk deep-link is acceptable on a LAN but logged in browser
  history; consider a one-time pairing flow for production.
- **Inter/SF Pro fonts** not bundled. Drop `.ttf` into `assets/fonts/` + `pubspec.yaml`.
- Camera/soil **firmware** still untested against the live API.

## Senior-project polish (completed this session)

Four production-shape improvements that are within the project's scope:

1. **InfluxDB UI no longer proxied** (`nginx/nginx.conf`). Removed the
   unauthenticated `/influxdb/` location block; operators use `docker exec`
   or port-forward when DB access is needed.
2. **Live SSE telemetry feed**:
   - `GET /api/v1/stream` tails the Redis `stream:telemetry` and emits SSE
     events. Tested for heartbeat behaviour and clean cancellation.
   - Dashboard subscribes on mount, merges each delta into the matching node
     card (`mergeDelta`), shows a `STREAM OFFLINE` header when the connection
     drops. Refresh re-subscribes.
3. **Firmware crash telemetry**:
   - Soil node sends `reset_reason` (e.g. `task_wdt`, `brownout`, `panic`)
     and `free_heap` on every cycle.
   - Backend caches them and exposes them through
     `GET /api/v1/node/{id}/telemetry`.
   - Card surfaces a red `DIAG` chip on any non-routine reset (anything other
     than `deepsleep` or `poweron`).
4. **GitHub Actions CI** at `.github/workflows/ci.yml` — three parallel jobs:
   backend pytest, Flutter analyze + test + web build, Docker image build for
   both api and dashboard. Concurrency-cancellation enabled.

Tests: **25 backend (was 24) + 1 Flutter widget test**, all passing.

## Suggested next step
Bring up the stack (`docker compose -f docker-compose.dev.yml up --build`),
verify the `STREAM OFFLINE` chip turns green when telemetry flows, then test
the agronomist chat once a Gemini key is in `.env`.
