# UI Redesign Implementation Plan (Sub-project ② of 3) — "evolved technical"

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Elevate the dashboard (web + Android, one codebase) into a modern, animated, image-rich "evolved technical" console per the approved spec — keeping the hard rule: no colorful blurred bubbles, no emojis, no round playful pill shapes.

**Architecture:** Design-system-first. Tokens + motion constants land in `app_theme.dart`; shared chrome consolidates into `widgets/`; screens then restyle on top. All imagery is live data (camera frames, code-drawn glyphs) — zero bundled photo assets. Branch: `ui-redesign` off `main`.

**Tech Stack:** Flutter (Material 3 dark), CustomPainter for gauges/glyphs/backdrops, implicit + explicit animations, Hero transitions, fl_chart (already a dependency).

## Global Constraints

- No emojis, no round pill shapes, no colorful blurred bubbles. Sharp corners (`BorderRadius.zero`) everywhere.
- Uppercase mono labels; existing palette (bgBase/bgLift/glass/health/warning/alert) stays the identity.
- No new heavy dependencies; all art is CustomPainter/gradient work.
- `flutter analyze` clean and `flutter test` green after every task.
- Respect reduced motion where trivial (Flutter's default animations are fine; nothing strobes).

---

### Task 1: Tokens + shared chrome consolidation

**Files:** `lib/theme/app_theme.dart`, `lib/widgets/glass.dart`, all screens (replace literals/copies).

- [ ] Add `AppColors.insetFill` (= the 6x-repeated `Color.fromRGBO(10,18,11,0.6)`) and use `AppColors.bgLift` for the 3x inline `Color(0xFF0E1A11)`.
- [ ] Add `AppMotion` (fast 150ms / base 250ms / slow 600ms / draw 900ms; `easeOutCubic`, `easeOutQuart`) — every new animation uses these.
- [ ] Add `CommandButton` to `glass.dart` (label/icon, color, filled/outline, onTap, loading) replacing `_CommandButton` (node_detail), `_CommandBtn` (automation), the chat send button, and `_ConnectButton` (login).
- [ ] Add `showAppToast(context, msg)` replacing the duplicated `_toast` in dashboard + node_detail.
- [ ] `flutter analyze` + commit.

### Task 2: Animated telemetry card (the grid's core)

**Files:** `lib/widgets/telemetry_card.dart`, `lib/widgets/painters.dart` (new), `lib/screens/dashboard_screen.dart` (frame fetch plumbing).

- [ ] `painters.dart`: `RingGaugePainter` (arc gauge, sweep-in + tween on change, tick marks, sharp square cap), `NodeGlyphPainter` (line-art soil probe / camera / zone glyphs), `CornerBrackets` (animated detection brackets).
- [ ] Card: moisture rendered as animated ring gauge; numeric readouts tick via `TweenAnimationBuilder`; SSE `updateTick` fires a brief border "data flash" + pulse dot.
- [ ] Camera cards: latest frame as dimmed background (gradient scrim; fetched via `fetchCameraFrame`, cached per node, refreshed when `detectionAt` changes), detection state = edge glow + corner brackets + confidence.
- [ ] Placeholder/no-reading cards show the node-kind glyph instead of dashes-only.
- [ ] Staggered entrance animation (per-index delay, once per mount).
- [ ] `flutter analyze` + commit.

### Task 3: Node detail — hero, vision panel, charts, actuator motion

**Files:** `lib/screens/node_detail_screen.dart`, `lib/widgets/painters.dart`.

- [ ] Hero transition: camera frame / gauge shared element (`Hero(tag: 'node-hero-<id>')`) from card to detail.
- [ ] Vision panel: full-bleed frame hero with corner brackets + scanline sweep animation on a fresh detection (`detectionAt` change).
- [ ] History charts: fl_chart draw-in (animated `LineChart` duration + gradient area fill under the line).
- [ ] Actuator panel: flowing-dash line animation while ON (CustomPainter, marching dashes), VIRTUAL/HARDWARE badge unchanged semantics.
- [ ] `flutter analyze` + commit.

### Task 4: Dashboard shell, alerts, login backdrop

**Files:** `lib/screens/dashboard_screen.dart`, `lib/screens/login_screen.dart`, `lib/widgets/glass.dart`.

- [ ] Alerts bar: slide/fade in on new raised alert (AnimatedSize + AnimatedSwitcher).
- [ ] Card hover/press: border brighten + shadow lift on web/desktop pointers.
- [ ] Login: slow animated technical grid backdrop (CustomPainter: faint grid + drifting scan band), fade-in of the console card.
- [ ] `flutter analyze` + commit.

### Task 5: Mobile shell

**Files:** `lib/screens/dashboard_screen.dart` (nav shell), screens.

- [ ] Under 700px: bottom navigation (GRID / ALERTS / AUTOMATION / AGRONOMIST) — sharp, mono-labelled; alerts tab shows the full alert list; agronomist tab hosts the chat panel full-screen.
- [ ] Pull-to-refresh on the grid (RefreshIndicator, health-green on bgLift).
- [ ] `HapticFeedback.mediumImpact()` on capture, zone commands, emergency stop.
- [ ] `flutter analyze` + `flutter test` + commit.

### Task 6: Verification gate

- [ ] `flutter analyze` clean, `flutter test` green.
- [ ] Rebuild dev dashboard container; visual pass on web (grid, detail, automation, login).
- [ ] Merge `ui-redesign` → `main`, tag `ui-redesign-complete`.
