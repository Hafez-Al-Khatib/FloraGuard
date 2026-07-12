# Project Assessment — 2026-07

Honest, prioritized state of the Plant Monitoring & Automation system after this
work cycle. Ordered P0 (blocking/critical) → P2 (polish). "Fix" = doable in
software; "Decide" = needs your call; "Hardware" = needs the device.

## Strengths (so the criticism has context)
The architecture is genuinely good: typed SSE event envelope, per-device auth
with a `Principal` model, write-once node registration, safety interlocks on
actuation (cooldown/cap/e-stop), a clean Cache/TSDB/Inference separation, 66
backend tests, offline-first design, and — new this cycle — coarse disease
grouping (44%→75%) and zone linking. The bones are solid; the weaknesses below
are mostly at the edges (data, deployment, one hardware link).

## P0 — Critical / blocking

1. **[Hardware] The soil node isn't publishing telemetry.** Every node reads
   `null` for every field. Verified the server pipeline is healthy (injected a
   reading over `POST /telemetry`, it flowed to cache→read API→UI immediately),
   so this is device-side. The whole system is data-starved until fixed —
   cards, history, alerts, automation all need real readings. Likely causes, in
   order: MQTT-over-TLS (8883) cert/credential mismatch in `secrets.h`; wrong
   broker host/IP; Wi-Fi/2.4 GHz association; wrong topic (must be
   `pms/telemetry/<node_id>`); deep-sleep publishing before the broker ACK.
   *Debug:* `mosquitto_sub -t 'pms/#' -v` on the Pi while the node boots.

2. **[Decide] Production is running the *bad* model.** `main` (and any deploy)
   still serves the 24%-field PlantVillage classifier. The field model + coarse
   grouping (75%) lives on the unmerged `ml-pipeline` branch. Every diagnosis
   users see today is the weak one. Merge `ml-pipeline` → `main` (it's tested,
   66 backend tests green) or cherry-pick the model + grouping.

3. **[Decide] Branch divergence.** Three lines of work are unmerged:
   `ml-pipeline` (ML + grouping + server input-size), `zone-linking` (this
   cycle's UI), and local edits. The longer they sit, the harder the merge.
   Establish a cadence: merge zone-linking and ml-pipeline to main this week.

## P1 — Important

4. **[Fix] Empty/offline state is ambiguous.** With all-null data the dashboard
   looks broken rather than "no device is reporting." The header says
   "SYSTEM LIVE" (SSE connected) even when zero nodes report. Add a
   "N/M NODES REPORTING" summary so a data outage is legible at a glance
   (see the fix landed alongside this doc).

5. **[Fix] Flutter-web is heavy.** CanvasKit gives slow first paint, poor
   accessibility (canvas has no DOM/semantics), and fragile automation (we
   couldn't screenshot it). Consider the `--web-renderer html` build for the
   kiosk, or enable semantics. Low effort, real UX/AX gain.

6. **[Hardware/ML] No in-domain data + single-frame vision.** The model has
   never seen a real ESP32-CAM frame from this greenhouse (the ceiling-breaker),
   and detection is whole-frame single-label — per-plant boxes (sub-project B)
   are scoped but not built.

7. **[Fix] Frontend test coverage was thin.** Improved this cycle (zone + tap
   tests) but there's still no end-to-end MQTT→UI integration test and limited
   widget coverage on the detail/automation screens.

## P2 — Polish / hygiene

8. **[Fix] Cloud chat key** — the Gemini key format was flagged earlier; verify
   streaming works against a real key, or the agronomist panel is dead weight.
9. **[Fix] CI doesn't cover ML** — `ci.yml` runs backend/flutter; the `ml/`
   pipeline and model artifacts aren't validated in CI.
10. **[Decide] Data retention/backup** — InfluxDB retention + a backup/restore
    script are documented but unverified end-to-end.
11. **[Fix] `_moistureState` thresholds** and the health palette are tuned for a
    generic crop; per-crop setpoints would be more accurate once zones carry a
    crop type.

## Fixed this cycle
- Zone linking (camera↔soil by node-id) across dashboard + app, live data.
- Coarse disease grouping (44%→75%) wired into the edge server + treatments.
- Mains-power display + removed the phantom temp readout (no sensor).
- Verified card clickability (tests) and the telemetry pipeline (injection).
- App-side TLS trust for the Pi; model input-size auto-detect.

## Recommended order of attack
1. **Get the soil node publishing** (P0.1) — unblocks everything; needs the device.
2. **Merge `zone-linking` + `ml-pipeline` → main** (P0.2/3) — ship the good model.
3. **Node-reporting health indicator** (P1.4) — done here.
4. Then: in-domain captures → object detection (B) → per-crop tuning.
