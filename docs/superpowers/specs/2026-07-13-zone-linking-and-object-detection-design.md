# Zone Linking + Per-Plant Detection — Design

Two related but independently-sized features for the camera/soil UI. Decomposed
into two sub-projects; **A ships first** (small, frontend-only), **B** is scoped
here and gets its own plan before any code.

## Context
- Nodes are independent. Profile = `{kind, label, fw}`; no zone/link concept.
- A camera stores exactly one latest diagnosis; the model is a whole-frame
  single-label classifier (cannot localize multiple plants).
- One Flutter codebase drives dashboard + phone app (only the responsive shell
  differs), so a UI change lands in both at once.

---

## Sub-project A — Zone linking (frontend-only)

**Goal:** a camera node (`camera-zone-a-1`) shows the live soil readings of its
zone sibling (`soil-zone-a-1`) and vice-versa, so an operator sees one plant
group's vision + soil together.

**Zone key:** `zoneOf(nodeId)` strips a leading device prefix
(`camera-`, `cam-`, `soil-`, `controller-`, `ctrl-`); the remainder is the zone.
`camera-zone-a-1` & `soil-zone-a-1` → `zone-a-1`. Nodes sharing a zone key are
linked. No backend change — the dashboard already holds every node's telemetry
in one map, and SSE keeps it live; the link is a pure lookup.

**Components / changes (all in `dashboard/lib`):**
- `models/telemetry.dart`: top-level `String? zoneOf(String nodeId)` +
  `TelemetrySnapshot.zone` getter; `TelemetrySnapshot.isSoil`.
- New `models/zone.dart` (or a helper): `TelemetrySnapshot? linkedPeer(
  Iterable<TelemetrySnapshot> all, TelemetrySnapshot self, {required bool wantSoil})`
  — same zone, opposite kind, nearest match.
- `screens/dashboard_screen.dart`: build a zone lookup once from `_telemetry`;
  pass each card its linked peer. `_openNodeDetail` also passes the peer.
- `widgets/telemetry_card.dart`: `TelemetryCard` gains `TelemetrySnapshot? linked`.
  - Camera card: a compact "ZONE SOIL" strip — moisture / temp / EC / battery
    from `linked` (or hidden if no soil sibling). Tapping opens the soil node.
  - Soil card: a small "＋VISION" chip with the linked camera's group diagnosis.
- `screens/node_detail_screen.dart`: accept an optional `linked` initial
  snapshot; subscribe to the sibling's SSE events too (broaden the node-id
  filter) so its readings stay live; render a "Zone Soil" panel on a camera
  detail (and a vision chip on a soil detail).

**Data flow:** dashboard fetch/SSE → `_telemetry` map → zone lookup → card/detail
render peer fields. No new endpoints, no schema change.

**Verification:** `flutter analyze` + `flutter test`; a widget test for
`zoneOf`/`linkedPeer`; visual pass (camera card shows soil strip; soil card shows
vision chip; no sibling → strip hidden).

---

## Sub-project B — Per-plant object detection (own plan required)

**Goal:** one frame → several labeled boxes, one per plant, each with a coarse
group + confidence, drawn on the image in card + detail.

**Model:** YOLO (ultralytics YOLOv8n/v11n) trained on **PlantDoc's native
bounding-box annotations** (it is originally a detection dataset), classes mapped
to the 5 coarse groups; exported to ONNX. Trained on Colab GPU (extends `ml/`).

**Backend:**
- New `Detector` (YOLO ONNX + letterbox preprocess + NMS) → list of
  `{box:[x,y,w,h] normalized, group, confidence}`.
- Detection record becomes a **list** of boxes; keep a `dominant` group +
  count summary for backward-compat with current consumers (card badge, alerts).
- `set/get_camera_diagnostics`, SSE `detection` payload, `/diagnostics`,
  `/analyze`, and upload auto-analyze carry the box list.
- Treatments aggregate the unique diseased groups present in the frame.
- Alerts: raise per diseased box above `disease_confidence_threshold`.

**UI:** `BoxOverlayPainter` (CustomPainter) draws normalized boxes scaled to the
displayed frame size, each with a group label chip, reusing the corner-bracket /
scanline aesthetic; on card (compact) and vision panel (full). Both surfaces.

**Risks / notes:** new training data path (boxes), letterbox coord math,
frame intrinsic-vs-displayed scaling, larger detection payload. Needs its own
spec-to-plan pass; do **not** fold into A.

**Sequencing:** ship A, then write B's plan (`docs/superpowers/plans/…`).
