import 'package:flutter/material.dart';

import '../models/telemetry.dart';
import '../theme/app_theme.dart';
import 'glass.dart';

/// Glass telemetry card: a single node's latest readings rendered as a rigid,
/// data-dense panel — headline moisture metric, micro telemetry bars, and a
/// two-column thermal/EC readout.
///
/// Animations:
///   - Metric value text cross-fades when it changes.
///   - On a fresh SSE delta (updateTick bump), the StatusChip flashes a brief
///     border accent so the operator gets visual confirmation a value is live.
///   - Stale nodes (>5 min since last contact) dim to 50% opacity and show a
///     STALE status override instead of the moisture-based health label.
class TelemetryCard extends StatefulWidget {
  final TelemetrySnapshot snapshot;
  final int index;
  final VoidCallback? onTap;

  const TelemetryCard({
    super.key,
    required this.snapshot,
    this.index = 1,
    this.onTap,
  });

  @override
  State<TelemetryCard> createState() => _TelemetryCardState();
}

class _TelemetryCardState extends State<TelemetryCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );
  int _lastTick = 0;

  @override
  void initState() {
    super.initState();
    _lastTick = widget.snapshot.updateTick;
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
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = widget.snapshot;
    final moisture = snapshot.moisture;
    final state = _moistureState(moisture);
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

    final card = Opacity(
      // Stale cards fade back so the eye is drawn to live ones first.
      opacity: stale ? 0.55 : 1.0,
      child: AnimatedBuilder(
        animation: _pulse,
        builder: (context, child) {
          // Pulse: brief sage glow that decays. We layer a second DecoratedBox
          // around the glass card during the animation rather than recreating
          // the glass itself.
          final t = 1.0 - _pulse.value;
          return DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(
                color: AppColors.health.withValues(alpha: 0.6 * t),
                width: 1,
              ),
              boxShadow: t > 0.01
                  ? [
                      BoxShadow(
                        color: AppColors.health.withValues(alpha: 0.25 * t),
                        blurRadius: 16 * t,
                      ),
                    ]
                  : const [],
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
                  StatusChip(state: headerState, labelOverride: headerLabel),
                ],
              ),
              const SizedBox(height: AppSpace.md),
              if (isCamera)
                _CameraBody(snapshot: snapshot)
              else
                _SoilBody(snapshot: snapshot, state: state),
              const SizedBox(height: AppSpace.sm),
              _LastSeenLine(ageSeconds: snapshot.ageSeconds),
            ],
          ),
        ),
      ),
    );

    if (widget.onTap == null) return card;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: card,
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

/// Soil-node card body: moisture headline, soil/battery bars, temp + EC readout.
class _SoilBody extends StatelessWidget {
  final TelemetrySnapshot snapshot;
  final HealthState state;
  const _SoilBody({required this.snapshot, required this.state});

  @override
  Widget build(BuildContext context) {
    final moisture = snapshot.moisture;
    final battery = snapshot.batteryPct;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            _AnimatedMetric(value: moisture, style: AppText.metric),
            const SizedBox(width: AppSpace.sm),
            Text('% VWC', style: AppText.monoCaption),
          ],
        ),
        const TechnicalDivider(),
        MicroBar(
          label: 'Soil Moisture',
          valueText: '${_fmt(moisture)}%',
          ratio: (moisture ?? 0) / 100.0,
          color: state.color,
        ),
        const SizedBox(height: AppSpace.md),
        MicroBar(
          label: 'Battery Reserve',
          valueText: '${_fmt(battery)}%',
          ratio: (battery ?? 0) / 100.0,
          color: _batteryColor(battery),
        ),
        const TechnicalDivider(),
        Row(
          children: [
            Expanded(
              child: _MiniReadout(
                label: 'Canopy Temp',
                value: snapshot.temperature,
                unit: '°C',
              ),
            ),
            const SizedBox(width: AppSpace.md),
            Expanded(
              child: _MiniReadout(label: 'EC', value: snapshot.ec, unit: 'mS/cm'),
            ),
          ],
        ),
        if (snapshot.hasActuator) ...[
          const SizedBox(height: AppSpace.sm),
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

/// Camera-node card body: latest disease detection as a headline + confidence.
class _CameraBody extends StatelessWidget {
  final TelemetrySnapshot snapshot;
  const _CameraBody({required this.snapshot});

  @override
  Widget build(BuildContext context) {
    if (!snapshot.hasDetection) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('AWAITING CAPTURE', style: AppText.monoCaption),
          const SizedBox(height: AppSpace.sm),
          Text('Upload a frame to run disease analysis.',
              style: AppText.monoCaption.copyWith(fontSize: 10)),
        ],
      );
    }
    final healthy = snapshot.detectionHealthy;
    final c = healthy ? AppColors.health : AppColors.alert;
    final conf = (snapshot.detectionConfidence ?? 0).clamp(0.0, 1.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          snapshot.detectionShort,
          style: AppText.title.copyWith(color: c, fontSize: 24),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: AppSpace.xs),
        Text(
          snapshot.detectionIssue!.toUpperCase(),
          style: AppText.monoCaption,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const TechnicalDivider(),
        MicroBar(
          label: 'Confidence',
          valueText: '${(conf * 100).toStringAsFixed(0)}%',
          ratio: conf,
          color: c,
        ),
        const SizedBox(height: AppSpace.sm),
        Text(
          'TAP FOR IMAGE & TREATMENT',
          style: AppText.monoCaption.copyWith(fontSize: 9, letterSpacing: 1.2),
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
        padding:
            const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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
