import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Crop-health status states drive accent color across chips and bars.
enum HealthState { optimal, warning, critical, neutral }

extension HealthStateColor on HealthState {
  Color get color {
    switch (this) {
      case HealthState.optimal:
        return AppColors.health;
      case HealthState.warning:
        return AppColors.warning;
      case HealthState.critical:
        return AppColors.alert;
      case HealthState.neutral:
        return AppColors.textSecondary;
    }
  }

  String get label {
    switch (this) {
      case HealthState.optimal:
        return 'OPTIMAL';
      case HealthState.warning:
        return 'STRESS WARNING';
      case HealthState.critical:
        return 'CRITICAL';
      case HealthState.neutral:
        return 'NO SIGNAL';
    }
  }
}

/// Physical glass card: real backdrop blur, translucent moss fill, sharp dark
/// drop shadow (not a diffused color glow), subtle top-left edge sheen, and a
/// thin sage border. Sharp corners by design.
class GlassCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;

  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AppSpace.lg),
  });

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        boxShadow: [
          BoxShadow(
            color: Color(0x80000000), // rgba(0,0,0,0.5) — sharp & dark
            blurRadius: 24,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Container(
            decoration: BoxDecoration(
              color: AppColors.glassFill,
              border: Border.all(color: AppColors.glassBorder, width: 1),
            ),
            child: Stack(
              children: [
                // Glass edge sheen (top-left highlight).
                const Positioned.fill(
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [Color(0x08FFFFFF), Color(0x00FFFFFF)],
                        ),
                      ),
                    ),
                  ),
                ),
                Padding(padding: padding, child: child),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Rigid horizontal divider: a 1px line fading from transparent through sage.
class TechnicalDivider extends StatelessWidget {
  final double vertical;
  const TechnicalDivider({super.key, this.vertical = AppSpace.md});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 1,
      margin: EdgeInsets.symmetric(vertical: vertical),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Colors.transparent, AppColors.sageFaint, Colors.transparent],
        ),
      ),
    );
  }
}

/// Uppercase micro section label, optionally numbered.
class SectionLabel extends StatelessWidget {
  final String text;
  const SectionLabel(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Text(text.toUpperCase(), style: AppText.microLabel);
  }
}

/// Sharp status tag with thin colored border and translucent fill.
class StatusChip extends StatelessWidget {
  final HealthState state;
  final String? labelOverride;
  const StatusChip({super.key, required this.state, this.labelOverride});

  @override
  Widget build(BuildContext context) {
    final c = state.color;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.10),
        border: Border.all(color: c.withValues(alpha: 0.25), width: 1),
      ),
      child: Text(
        labelOverride ?? state.label,
        style: AppText.monoCaption.copyWith(
          color: c,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// A labelled thin telemetry bar (no rounded fills) with a 0..1 ratio.
class MicroBar extends StatelessWidget {
  final String label;
  final String valueText;
  final double ratio; // 0..1
  final Color color;

  const MicroBar({
    super.key,
    required this.label,
    required this.valueText,
    required this.ratio,
    this.color = AppColors.health,
  });

  @override
  Widget build(BuildContext context) {
    final clamped = ratio.clamp(0.0, 1.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label.toUpperCase(), style: AppText.monoCaption),
            Text(valueText, style: AppText.monoValue),
          ],
        ),
        const SizedBox(height: AppSpace.sm),
        SizedBox(
          height: 4,
          child: Stack(
            children: [
              const Positioned.fill(
                child: ColoredBox(color: AppColors.sageFaint),
              ),
              FractionallySizedBox(
                widthFactor: clamped,
                alignment: Alignment.centerLeft,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 500),
                  curve: Curves.easeOut,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Slow-pulsing square live indicator (no playful shapes; sharp 2px square).
class LiveIndicator extends StatefulWidget {
  final Color color;
  const LiveIndicator({super.key, this.color = AppColors.health});

  @override
  State<LiveIndicator> createState() => _LiveIndicatorState();
}

class _LiveIndicatorState extends State<LiveIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 4),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fade = Tween(begin: 0.3, end: 1.0).animate(
      CurvedAnimation(parent: _c, curve: Curves.easeInOut),
    );
    return FadeTransition(
      opacity: fade,
      child: Container(width: 8, height: 8, color: widget.color),
    );
  }
}

/// Background wash: a subtle monochromatic vertical gradient so the glass blur
/// has gentle tonal variation to refract. Deliberately not a colorful bubble.
class NatureBackground extends StatelessWidget {
  final Widget child;
  const NatureBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [AppColors.bgLift, AppColors.bgBase],
        ),
      ),
      child: child,
    );
  }
}
