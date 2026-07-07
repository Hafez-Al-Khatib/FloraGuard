import 'package:flutter/material.dart';

/// PREMIUM GLASS-NATURE design system.
///
/// Strict mode: no ambient colorful blurred bubbles, no emojis, no playful
/// pill shapes. Rigid technical structure, sharp dark shadows, sophisticated
/// nature palette.
class AppColors {
  AppColors._();

  /// Deep Forest Obsidian — very dark charcoal-green app base.
  static const bgBase = Color(0xFF0A120B);

  /// A slightly lifted obsidian for the subtle background gradient so the glass
  /// blur has something to refract (kept monochromatic, not a colorful bubble).
  static const bgLift = Color(0xFF0E1A11);

  /// Translucent Dark Moss — the glass card fill.
  static const glassFill = Color.fromRGBO(18, 30, 20, 0.45);

  /// Subtle Sage Line — glass borders.
  static const glassBorder = Color.fromRGBO(74, 117, 89, 0.20);
  static const glassBorderHover = Color.fromRGBO(74, 117, 89, 0.35);
  static const sageFaint = Color.fromRGBO(74, 117, 89, 0.12);

  /// Recessed input/panel fill — darker than the glass so fields read as
  /// cut INTO the card. One token instead of the 6 inline copies it replaces.
  static const insetFill = Color.fromRGBO(10, 18, 11, 0.6);

  static const textPrimary = Color(0xFFF4F7F5); // Crisp Off-White
  static const textSecondary = Color(0xFF8FA899); // Muted Eucalyptus Green

  static const health = Color(0xFF3BD16F); // Vibrant Chlorophyll Green
  static const warning = Color(0xFFD9A05B); // Dry Straw Gold
  static const alert = Color(0xFFE06666); // Wilted Rust Red
}

/// Motion scale. Every animation in the app draws from these four durations
/// and two curves so the whole console moves with one rhythm.
class AppMotion {
  AppMotion._();
  static const fast = Duration(milliseconds: 150); // hover, press
  static const base = Duration(milliseconds: 250); // state changes, fades
  static const slow = Duration(milliseconds: 600); // gauges, bars, reveals
  static const draw = Duration(milliseconds: 900); // chart draw-in, sweeps
  static const curve = Curves.easeOutCubic;
  static const emphasize = Curves.easeOutQuart;
}

/// Monospace stack for high-density telemetry readouts. Uses platform/system
/// monospace fallbacks — no network font fetch, preserving the offline-first
/// guarantee of the edge deployment.
const List<String> kMonoFallback = <String>[
  'SFMono-Regular',
  'Menlo',
  'Consolas',
  'Roboto Mono',
  'monospace',
];

class AppText {
  AppText._();

  static const _mono = 'monospace';

  /// Uppercase micro-label (section headers, units).
  static const microLabel = TextStyle(
    color: AppColors.textSecondary,
    fontSize: 11,
    fontWeight: FontWeight.w600,
    letterSpacing: 1.4,
    height: 1.2,
  );

  /// Monospace technical caption (node ids, status, raw values).
  static const monoCaption = TextStyle(
    fontFamily: _mono,
    fontFamilyFallback: kMonoFallback,
    color: AppColors.textSecondary,
    fontSize: 11,
    letterSpacing: 0.5,
    height: 1.3,
  );

  static const monoValue = TextStyle(
    fontFamily: _mono,
    fontFamilyFallback: kMonoFallback,
    color: AppColors.textPrimary,
    fontSize: 12,
    letterSpacing: 0.5,
  );

  /// Large light readout for headline metric values.
  static const metric = TextStyle(
    color: AppColors.textPrimary,
    fontSize: 38,
    fontWeight: FontWeight.w200,
    letterSpacing: -0.5,
    height: 1.0,
  );

  static const title = TextStyle(
    color: AppColors.textPrimary,
    fontSize: 22,
    fontWeight: FontWeight.w300,
    letterSpacing: -0.4,
  );
}

/// Spacing scale (4pt grid) for explicit, aligned layouts.
class AppSpace {
  AppSpace._();
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 16.0;
  static const lg = 24.0;
  static const xl = 32.0;
}

ThemeData buildAppTheme() {
  final base = ThemeData.dark(useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: AppColors.bgBase,
    colorScheme: const ColorScheme.dark(
      surface: AppColors.bgBase,
      primary: AppColors.health,
      secondary: AppColors.textSecondary,
      error: AppColors.alert,
      onPrimary: AppColors.bgBase,
      onSurface: AppColors.textPrimary,
    ),
    textSelectionTheme: const TextSelectionThemeData(
      selectionColor: Color.fromRGBO(59, 209, 111, 0.30),
      cursorColor: AppColors.health,
    ),
    splashColor: const Color.fromRGBO(59, 209, 111, 0.06),
    highlightColor: Colors.transparent,
  );
}
