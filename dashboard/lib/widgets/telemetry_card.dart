import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/telemetry.dart';
import '../providers/app_state.dart';
import '../theme/app_theme.dart';
import 'glass.dart';
import 'painters.dart';

/// Glass telemetry card: a single node's latest readings rendered as a rigid,
/// data-dense panel. Soil nodes headline an animated ring gauge; camera nodes
/// headline their latest frame with viewfinder brackets; unpaired/quiet nodes
/// show a code-drawn node glyph instead of bare dashes.
///
/// Animations (all drawn from [AppMotion]):
///   - Staggered fade + slide entrance, once per mount, offset by grid index.
///   - Moisture gauge sweeps in and tweens between values.
///   - On a fresh SSE delta (updateTick bump) a brief sage border "data flash"
///     + header pulse dot confirm the value is live.
///   - Camera frames fade in with corner brackets; a disease hit adds edge glow.
///   - Stale nodes (>5 min since last contact) dim to 55% opacity and show a
///     STALE status override instead of the moisture-based health label.
class TelemetryCard extends StatefulWidget {
  final TelemetrySnapshot snapshot;
  final int index;
  final VoidCallback? onTap;
  // Zone sibling (opposite kind): the soil node for a camera, or the camera for
  // a soil node. Null when the zone has no such peer. Drives the zone-link strip.
  final TelemetrySnapshot? linked;

  const TelemetryCard({
    super.key,
    required this.snapshot,
    this.index = 1,
    this.onTap,
    this.linked,
  });

  @override
  State<TelemetryCard> createState() => _TelemetryCardState();
}

class _TelemetryCardState extends State<TelemetryCard>
    with TickerProviderStateMixin {
  // Rest at 1.0 → no glow; a fresh delta forwards from 0.0 so the glow flashes
  // in and decays as the controller settles back at 1.0.
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );
  late final AnimationController _entrance = AnimationController(
    vsync: this,
    duration: AppMotion.slow,
  );
  int _lastTick = 0;

  // Latest camera frame bytes, cached per detection so we only re-fetch when
  // a new frame actually arrives (detectionAt advances).
  Uint8List? _frame;
  DateTime? _frameFor;
  bool _fetching = false;
  bool _hover = false;

  @override
  void initState() {
    super.initState();
    _lastTick = widget.snapshot.updateTick;
    _pulse.value = 1.0;
    // Staggered entrance: later cards in the grid animate in slightly after the
    // first. Capped so a large grid doesn't cascade for seconds.
    final delayMs = (widget.index.clamp(1, 12) - 1) * 55;
    Future.delayed(Duration(milliseconds: delayMs), () {
      if (mounted) _entrance.forward();
    });
    _maybeFetchFrame();
  }

  @override
  void didUpdateWidget(covariant TelemetryCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Re-trigger the pulse only on an actual fresh delta — not on rebuilds
    // caused by parent-widget refreshes.
    if (widget.snapshot.updateTick != _lastTick) {
      _lastTick = widget.snapshot.updateTick;
      _pulse.forward(from: 0.0);
    }
    _maybeFetchFrame();
  }

  /// Fetch the camera frame once, and again whenever the detection timestamp
  /// advances. No-op for non-camera nodes and while a fetch is in flight.
  void _maybeFetchFrame() {
    final snap = widget.snapshot;
    if (!snap.isCamera || _fetching) return;
    final at = snap.detectionAt;
    if (_frame != null && _frameFor == at) return;
    final api = context.read<AppState>().api;
    if (api == null) return;
    _fetching = true;
    _frameFor = at;
    api.fetchCameraFrame(snap.nodeId).then((bytes) {
      if (!mounted) {
        _fetching = false;
        return;
      }
      setState(() {
        if (bytes != null) _frame = bytes;
        _fetching = false;
      });
    });
  }

  @override
  void dispose() {
    _pulse.dispose();
    _entrance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = widget.snapshot;
    final state = _moistureState(snapshot.moisture);
    final ordinal = widget.index.toString().padLeft(2, '0');
    final stale = snapshot.isStale;
    final isCamera = snapshot.isCamera;

    // The header status chip adapts to the node type.
    HealthState headerState;
    String? headerLabel;
    if (stale) {
      headerState = HealthState.neutral;
      headerLabel = 'STALE';
    } else if (isCamera) {
      if (!snapshot.hasDetection) {
        headerState = HealthState.neutral;
        headerLabel = 'NO SCAN';
      } else if (snapshot.detectionHealthy) {
        headerState = HealthState.optimal;
        headerLabel = 'HEALTHY';
      } else {
        headerState = HealthState.critical;
        headerLabel = 'DISEASE';
      }
    } else {
      headerState = state;
      headerLabel = null;
    }

    Widget body;
    if (isCamera) {
      body = _CameraBody(snapshot: snapshot, frame: _frame);
    } else if (!snapshot.hasReadings) {
      body = _PlaceholderBody(
        glyph: snapshot.hasActuator ? NodeGlyph.controller : NodeGlyph.soil,
      );
    } else {
      body = _SoilBody(snapshot: snapshot, state: state);
    }

    final card = Opacity(
      // Stale cards fade back so the eye is drawn to live ones first.
      opacity: stale ? 0.55 : 1.0,
      child: AnimatedBuilder(
        animation: _pulse,
        builder: (context, child) {
          // Pulse: brief sage glow that decays. We layer a DecoratedBox around
          // the glass card during the animation rather than recreating the
          // glass itself.
          final t = 1.0 - _pulse.value;
          final glow = 0.6 * t;
          // A live pulse takes precedence; otherwise a hovered card brightens
          // its border. Sharp shadow (not a diffused glow) lifts on hover.
          final Color borderColor;
          if (glow > 0.01) {
            borderColor = AppColors.health.withValues(alpha: glow);
          } else if (_hover) {
            borderColor = AppColors.glassBorderHover;
          } else {
            borderColor = const Color(0x00000000);
          }
          return AnimatedContainer(
            duration: AppMotion.fast,
            curve: AppMotion.curve,
            decoration: BoxDecoration(
              border: Border.all(color: borderColor, width: 1),
              boxShadow: [
                if (t > 0.01)
                  BoxShadow(
                    color: AppColors.health.withValues(alpha: 0.25 * t),
                    blurRadius: 16 * t,
                  ),
                if (_hover && t <= 0.01)
                  const BoxShadow(
                    color: Color(0x66000000),
                    blurRadius: 28,
                    offset: Offset(0, 14),
                  ),
              ],
            ),
            child: child,
          );
        },
        child: GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SectionLabel(isCamera
                            ? '$ordinal. Crop Vision'
                            : '$ordinal. Hydration Index'),
                        const SizedBox(height: AppSpace.xs),
                        Text(snapshot.nodeId.toUpperCase(),
                            style: AppText.monoCaption),
                      ],
                    ),
                  ),
                  if (!snapshot.bootHealthy) ...[
                    _DiagBadge(reason: snapshot.resetReason!),
                    const SizedBox(width: AppSpace.sm),
                  ],
                  _PulseDot(pulse: _pulse),
                  StatusChip(state: headerState, labelOverride: headerLabel),
                ],
              ),
              const SizedBox(height: AppSpace.md),
              body,
              if (widget.linked != null)
                _ZoneLinkStrip(self: snapshot, peer: widget.linked!),
              const SizedBox(height: AppSpace.sm),
              _LastSeenLine(ageSeconds: snapshot.ageSeconds),
            ],
          ),
        ),
      ),
    );

    // Entrance: fade + a short upward slide, driven once on mount.
    final entered = FadeTransition(
      opacity: _entrance.drive(CurveTween(curve: AppMotion.curve)),
      child: SlideTransition(
        position: _entrance.drive(
          Tween<Offset>(begin: const Offset(0, 0.06), end: Offset.zero)
              .chain(CurveTween(curve: AppMotion.curve)),
        ),
        child: card,
      ),
    );

    if (widget.onTap == null) return entered;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: entered,
      ),
    );
  }
}

// ── shared formatting helpers ────────────────────────────────────────────────
String _fmt(double? v) => v == null ? '--' : v.toStringAsFixed(1);

HealthState _moistureState(double? m) {
  if (m == null) return HealthState.neutral;
  if (m >= 40 && m <= 70) return HealthState.optimal;
  if (m >= 25 && m < 40) return HealthState.warning;
  if (m > 70 && m <= 85) return HealthState.warning;
  return HealthState.critical;
}

Color _batteryColor(double? b) {
  if (b == null) return AppColors.textSecondary;
  if (b >= 40) return AppColors.health;
  if (b >= 20) return AppColors.warning;
  return AppColors.alert;
}

/// Shared Hero tag so a card's gauge/frame morphs into the detail screen's.
String heroTagFor(String nodeId) => 'node-hero-$nodeId';

/// Header pulse dot: a sharp 6px square that flashes on a fresh delta and is
/// invisible at rest. Shares the [_pulse] controller with the border flash.
class _PulseDot extends StatelessWidget {
  final Animation<double> pulse;
  const _PulseDot({required this.pulse});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: pulse,
      builder: (_, __) {
        final t = 1.0 - pulse.value;
        if (t < 0.01) return const SizedBox(width: 0, height: 0);
        return Padding(
          padding: const EdgeInsets.only(right: AppSpace.sm, top: 3),
          child: Opacity(
            opacity: t,
            child: Container(width: 6, height: 6, color: AppColors.health),
          ),
        );
      },
    );
  }
}

/// Soil-node card body: moisture ring gauge + temp/EC readouts, battery bar,
/// optional irrigation status.
class _SoilBody extends StatelessWidget {
  final TelemetrySnapshot snapshot;
  final HealthState state;
  const _SoilBody({required this.snapshot, required this.state});

  @override
  Widget build(BuildContext context) {
    final battery = snapshot.batteryPct;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Hero(
              tag: heroTagFor(snapshot.nodeId),
              child: MoistureGauge(
                moisture: snapshot.moisture,
                color: state.color,
              ),
            ),
            const SizedBox(width: AppSpace.lg),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // No temp sensor on the current hardware — EC only.
                  _MiniReadout(label: 'EC', value: snapshot.ec, unit: 'mS/cm'),
                ],
              ),
            ),
          ],
        ),
        const TechnicalDivider(),
        if (snapshot.isMains)
          MicroBar(
            label: 'Power // Mains',
            valueText: '100%',
            ratio: 1.0,
            color: AppColors.health,
          )
        else
          MicroBar(
            label: 'Battery Reserve',
            valueText: '${_fmt(battery)}%',
            ratio: (battery ?? 0) / 100.0,
            color: _batteryColor(battery),
          ),
        if (snapshot.hasActuator) ...[
          const SizedBox(height: AppSpace.md),
          _IrrigationRow(snapshot: snapshot),
        ],
      ],
    );
  }
}

/// Compact irrigation actuator status shown on a soil card.
class _IrrigationRow extends StatelessWidget {
  final TelemetrySnapshot snapshot;
  const _IrrigationRow({required this.snapshot});

  @override
  Widget build(BuildContext context) {
    final on = snapshot.actuatorOn == true;
    final virtual = snapshot.actuatorBound != 'hardware';
    final c = on ? AppColors.health : AppColors.textSecondary;
    return Row(
      children: [
        Icon(Icons.water_drop, size: 12, color: c),
        const SizedBox(width: AppSpace.xs),
        Text('IRRIGATION ${on ? 'ON' : 'OFF'}',
            style: AppText.monoCaption.copyWith(color: c)),
        const SizedBox(width: AppSpace.sm),
        if (virtual)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              border: Border.all(color: AppColors.warning.withValues(alpha: 0.5)),
            ),
            child: Text('VIRTUAL',
                style: AppText.monoCaption.copyWith(
                    color: AppColors.warning, fontSize: 8, letterSpacing: 1)),
          ),
      ],
    );
  }
}

/// Camera-node card body: latest frame as the hero, dimmed under a scrim with
/// animated viewfinder brackets, disease edge glow, and the detection headline.
class _CameraBody extends StatelessWidget {
  final TelemetrySnapshot snapshot;
  final Uint8List? frame;
  const _CameraBody({required this.snapshot, this.frame});

  @override
  Widget build(BuildContext context) {
    final hasDet = snapshot.hasDetection;
    final healthy = snapshot.detectionHealthy;
    final c = !hasDet
        ? AppColors.textSecondary
        : (healthy ? AppColors.health : AppColors.alert);
    final diseased = hasDet && !healthy;
    final conf = (snapshot.detectionConfidence ?? 0).clamp(0.0, 1.0);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Hero(
          tag: heroTagFor(snapshot.nodeId),
          child: AspectRatio(
          aspectRatio: 16 / 10,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: AppColors.insetFill,
              border: Border.all(color: c.withValues(alpha: 0.4)),
              boxShadow: diseased
                  ? [
                      BoxShadow(
                        color: AppColors.alert.withValues(alpha: 0.35),
                        blurRadius: 14,
                      ),
                    ]
                  : const [],
            ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (frame != null)
                  Image.memory(frame!, fit: BoxFit.cover, gaplessPlayback: true)
                else
                  Center(
                    child: SizedBox(
                      width: 48,
                      height: 48,
                      child: CustomPaint(
                        painter: NodeGlyphPainter(glyph: NodeGlyph.camera),
                      ),
                    ),
                  ),
                // Scrim so the overlaid label stays legible on any frame.
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0x00000000), Color(0xCC000000)],
                    ),
                  ),
                ),
                if (frame != null)
                  TweenAnimationBuilder<double>(
                    tween: Tween<double>(begin: 0, end: 1),
                    duration: AppMotion.draw,
                    curve: AppMotion.curve,
                    builder: (_, r, __) => CustomPaint(
                      painter: CornerBracketsPainter(color: c, reveal: r),
                    ),
                  ),
                if (hasDet)
                  Positioned(
                    left: AppSpace.sm,
                    right: AppSpace.sm,
                    bottom: AppSpace.sm,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          snapshot.detectionShort,
                          style: AppText.title.copyWith(color: c, fontSize: 20),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          snapshot.detectionIssue!.toUpperCase(),
                          style: AppText.monoCaption,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  )
                else
                  Positioned(
                    left: AppSpace.sm,
                    bottom: AppSpace.sm,
                    child: Text('AWAITING CAPTURE', style: AppText.monoCaption),
                  ),
              ],
            ),
          ),
          ),
        ),
        if (hasDet) ...[
          const SizedBox(height: AppSpace.md),
          MicroBar(
            label: 'Confidence',
            valueText: '${(conf * 100).toStringAsFixed(0)}%',
            ratio: conf,
            color: c,
          ),
        ],
        const SizedBox(height: AppSpace.sm),
        Text(
          'TAP FOR IMAGE & TREATMENT',
          style: AppText.monoCaption.copyWith(fontSize: 9, letterSpacing: 1.2),
        ),
      ],
    );
  }
}

/// Placeholder body for a paired node we have no readings from yet — shows the
/// node-kind glyph instead of a column of dashes.
class _PlaceholderBody extends StatelessWidget {
  final NodeGlyph glyph;
  const _PlaceholderBody({required this.glyph});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 88,
          child: Center(
            child: SizedBox(
              width: 72,
              height: 72,
              child: CustomPaint(
                painter: NodeGlyphPainter(
                  glyph: glyph,
                  color: AppColors.textSecondary,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: AppSpace.sm),
        Center(child: Text('AWAITING TELEMETRY', style: AppText.monoCaption)),
      ],
    );
  }
}

/// Zone link: on a camera card, the linked soil node's live readings; on a soil
/// card, the linked camera's latest diagnosis. Data is real — [peer] is the
/// sibling's own snapshot, kept live by the same SSE stream.
class _ZoneLinkStrip extends StatelessWidget {
  final TelemetrySnapshot self;
  final TelemetrySnapshot peer;
  const _ZoneLinkStrip({required this.self, required this.peer});

  @override
  Widget build(BuildContext context) {
    final showSoil = self.isCamera; // camera → soil readings; soil → vision
    return Padding(
      padding: const EdgeInsets.only(top: AppSpace.md),
      child: Container(
        padding: const EdgeInsets.all(AppSpace.sm),
        decoration: const BoxDecoration(
          color: AppColors.insetFill,
          border: Border(left: BorderSide(color: AppColors.health, width: 2)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.link, size: 11, color: AppColors.textSecondary),
                const SizedBox(width: AppSpace.xs),
                Expanded(
                  child: Text(
                    '${showSoil ? 'ZONE SOIL' : 'ZONE VISION'} // ${peer.nodeId.toUpperCase()}',
                    style: AppText.monoCaption
                        .copyWith(fontSize: 9, letterSpacing: 1),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpace.xs),
            if (showSoil) _soilFacts() else _visionFact(),
          ],
        ),
      ),
    );
  }

  Widget _soilFacts() {
    String f(double? v, String u) =>
        v == null ? '--' : '${v.toStringAsFixed(v.abs() >= 10 ? 0 : 1)}$u';
    return Wrap(
      spacing: AppSpace.md,
      runSpacing: 4,
      children: [
        _fact('VWC', f(peer.moisture, '%')),
        _fact('EC', f(peer.ec, '')),
        // No temp sensor; mains-powered → power reads full.
        _fact('PWR', peer.isMains ? 'MAINS' : f(peer.batteryPct, '%')),
      ],
    );
  }

  Widget _fact(String k, String v) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('$k ', style: AppText.monoCaption.copyWith(fontSize: 9)),
          Text(v, style: AppText.monoValue.copyWith(fontSize: 11)),
        ],
      );

  Widget _visionFact() {
    if (!peer.hasDetection) {
      return Text('AWAITING SCAN',
          style: AppText.monoCaption.copyWith(fontSize: 10));
    }
    final c = peer.detectionHealthy ? AppColors.health : AppColors.alert;
    final conf = ((peer.detectionConfidence ?? 0) * 100).toStringAsFixed(0);
    return Row(
      children: [
        Icon(Icons.center_focus_weak, size: 12, color: c),
        const SizedBox(width: AppSpace.xs),
        Expanded(
          child: Text(
            '${peer.detectionShort} · $conf%',
            style: AppText.monoValue.copyWith(fontSize: 11, color: c),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

/// Cross-fades whenever the displayed value changes. Uses the formatted string
/// as the AnimatedSwitcher key so identical numeric values don't re-trigger.
class _AnimatedMetric extends StatelessWidget {
  final double? value;
  final TextStyle style;
  const _AnimatedMetric({required this.value, required this.style});

  String _fmt() => value == null ? '--' : value!.toStringAsFixed(1);

  @override
  Widget build(BuildContext context) {
    final text = _fmt();
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 360),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      transitionBuilder: (child, anim) {
        // Subtle vertical slide + fade — no bounce or scale to keep the
        // technical aesthetic.
        return FadeTransition(
          opacity: anim,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.12),
              end: Offset.zero,
            ).animate(anim),
            child: child,
          ),
        );
      },
      child: Text(text, key: ValueKey('metric-$text'), style: style),
    );
  }
}

/// One-line "12s ago" style indicator under the readout panel.
class _LastSeenLine extends StatelessWidget {
  final int? ageSeconds;
  const _LastSeenLine({required this.ageSeconds});

  String _formatAge() {
    final a = ageSeconds;
    if (a == null) return 'AWAITING TELEMETRY';
    if (a < 60) return 'LAST CONTACT $a s AGO';
    if (a < 3600) return 'LAST CONTACT ${(a / 60).floor()} m AGO';
    return 'LAST CONTACT ${(a / 3600).floor()} h AGO';
  }

  @override
  Widget build(BuildContext context) {
    final stale = (ageSeconds ?? 0) > 300;
    return Text(
      _formatAge(),
      style: AppText.monoCaption.copyWith(
        color: stale ? AppColors.warning : AppColors.textSecondary,
        fontSize: 9,
        letterSpacing: 1.2,
      ),
    );
  }
}

/// Surfaces a non-normal firmware reset reason as a small alert chip.
/// Hidden when the last boot was a routine deep-sleep wake or cold power-on.
class _DiagBadge extends StatelessWidget {
  final String reason;
  const _DiagBadge({required this.reason});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Last boot: $reason',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: AppColors.alert.withValues(alpha: 0.15),
          border: Border.all(color: AppColors.alert.withValues(alpha: 0.5)),
        ),
        child: Text(
          'DIAG',
          style: AppText.monoCaption.copyWith(
            color: AppColors.alert,
            fontSize: 9,
            letterSpacing: 1.5,
          ),
        ),
      ),
    );
  }
}

class _MiniReadout extends StatelessWidget {
  final String label;
  final double? value;
  final String unit;

  const _MiniReadout({required this.label, this.value, required this.unit});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label.toUpperCase(), style: AppText.monoCaption),
        const SizedBox(height: AppSpace.xs),
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            _AnimatedMetric(
              value: value,
              style: AppText.monoValue.copyWith(fontSize: 16),
            ),
            const SizedBox(width: 4),
            Text(unit, style: AppText.monoCaption),
          ],
        ),
      ],
    );
  }
}
