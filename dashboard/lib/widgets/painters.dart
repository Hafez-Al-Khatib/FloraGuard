import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Code-drawn art for the "evolved technical" look. Everything in here is a
/// CustomPainter — zero bundled image assets, sharp geometry only (no round
/// pill shapes, no blurred color bubbles).

// ── Ring gauge ───────────────────────────────────────────────────────────────

/// Square-capped arc gauge with tick marks. The sweep animates via the
/// [progress] the caller tweens (0..1 of [value]).
class RingGaugePainter extends CustomPainter {
  final double value; // 0..100
  final double progress; // 0..1 animation progress of the sweep
  final Color color;

  RingGaugePainter({
    required this.value,
    required this.progress,
    required this.color,
  });

  static const _startAngle = 3 * math.pi / 4; // gap at the bottom
  static const _maxSweep = 3 * math.pi / 2;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2 - 3;
    final rect = Rect.fromCircle(center: center, radius: radius);

    // Track.
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = AppColors.sageFaint;
    canvas.drawArc(rect, _startAngle, _maxSweep, false, track);

    // Value arc — butt cap keeps the ends square/technical.
    final sweep = _maxSweep * (value.clamp(0, 100) / 100) * progress;
    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.butt
      ..color = color;
    canvas.drawArc(rect, _startAngle, sweep, false, arc);

    // Tick marks every 10% along the track.
    final tick = Paint()
      ..strokeWidth = 1
      ..color = AppColors.glassBorder;
    for (var i = 0; i <= 10; i++) {
      final a = _startAngle + _maxSweep * i / 10;
      final outer = center + Offset(math.cos(a), math.sin(a)) * radius;
      final inner =
          center + Offset(math.cos(a), math.sin(a)) * (radius - 5);
      canvas.drawLine(inner, outer, tick);
    }
  }

  @override
  bool shouldRepaint(RingGaugePainter old) =>
      old.value != value || old.progress != progress || old.color != color;
}

// ── Node-kind glyphs ─────────────────────────────────────────────────────────

enum NodeGlyph { soil, camera, controller }

/// Minimal line-art glyphs for node kinds, used on placeholder cards and
/// empty states. Single-stroke technical drawings.
class NodeGlyphPainter extends CustomPainter {
  final NodeGlyph glyph;
  final Color color;

  NodeGlyphPainter({required this.glyph, this.color = AppColors.textSecondary});

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = color;
    final w = size.width, h = size.height;

    switch (glyph) {
      case NodeGlyph.soil:
        // Probe body + stem + soil line with hatching.
        canvas.drawRect(Rect.fromLTWH(w * 0.38, h * 0.05, w * 0.24, h * 0.30), p);
        canvas.drawLine(Offset(w * 0.5, h * 0.35), Offset(w * 0.5, h * 0.78), p);
        // Probe tip.
        final tip = Path()
          ..moveTo(w * 0.44, h * 0.78)
          ..lineTo(w * 0.5, h * 0.92)
          ..lineTo(w * 0.56, h * 0.78)
          ..close();
        canvas.drawPath(tip, p);
        // Soil line + hatches.
        canvas.drawLine(Offset(w * 0.08, h * 0.62), Offset(w * 0.92, h * 0.62), p);
        for (var i = 0; i < 4; i++) {
          final x = w * (0.14 + i * 0.22);
          canvas.drawLine(Offset(x, h * 0.62), Offset(x - w * 0.06, h * 0.72), p);
        }
      case NodeGlyph.camera:
        // Body, lens rings, indicator.
        canvas.drawRect(
            Rect.fromLTWH(w * 0.12, h * 0.25, w * 0.76, h * 0.5), p);
        canvas.drawCircle(Offset(w * 0.5, h * 0.5), w * 0.16, p);
        canvas.drawCircle(Offset(w * 0.5, h * 0.5), w * 0.07, p);
        canvas.drawRect(
            Rect.fromLTWH(w * 0.72, h * 0.32, w * 0.08, h * 0.08), p);
        // Mount stem.
        canvas.drawLine(Offset(w * 0.5, h * 0.75), Offset(w * 0.5, h * 0.9), p);
      case NodeGlyph.controller:
        // Valve: two triangles nose-to-nose + actuator stem.
        final left = Path()
          ..moveTo(w * 0.12, h * 0.35)
          ..lineTo(w * 0.5, h * 0.55)
          ..lineTo(w * 0.12, h * 0.75)
          ..close();
        final right = Path()
          ..moveTo(w * 0.88, h * 0.35)
          ..lineTo(w * 0.5, h * 0.55)
          ..lineTo(w * 0.88, h * 0.75)
          ..close();
        canvas.drawPath(left, p);
        canvas.drawPath(right, p);
        canvas.drawLine(Offset(w * 0.5, h * 0.55), Offset(w * 0.5, h * 0.2), p);
        canvas.drawRect(Rect.fromLTWH(w * 0.4, h * 0.08, w * 0.2, h * 0.12), p);
    }
  }

  @override
  bool shouldRepaint(NodeGlyphPainter old) =>
      old.glyph != glyph || old.color != color;
}

// ── Detection corner brackets ────────────────────────────────────────────────

/// Viewfinder-style corner brackets drawn over a camera frame. [reveal]
/// animates them growing out of the corners (0..1).
class CornerBracketsPainter extends CustomPainter {
  final Color color;
  final double reveal;

  CornerBracketsPainter({required this.color, this.reveal = 1.0});

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = color;
    final len = (size.shortestSide * 0.18) * reveal.clamp(0.0, 1.0);
    const inset = 4.0;
    final w = size.width, h = size.height;

    void corner(Offset o, double dx, double dy) {
      canvas.drawLine(o, o + Offset(len * dx, 0), p);
      canvas.drawLine(o, o + Offset(0, len * dy), p);
    }

    corner(const Offset(inset, inset), 1, 1);
    corner(Offset(w - inset, inset), -1, 1);
    corner(Offset(inset, h - inset), 1, -1);
    corner(Offset(w - inset, h - inset), -1, -1);
  }

  @override
  bool shouldRepaint(CornerBracketsPainter old) =>
      old.color != color || old.reveal != reveal;
}

/// Horizontal scanline sweep over a frame while/after analysis. [t] is the
/// 0..1 sweep position; the line carries a short trailing gradient.
class ScanlinePainter extends CustomPainter {
  final double t;
  final Color color;

  ScanlinePainter({required this.t, this.color = AppColors.health});

  @override
  void paint(Canvas canvas, Size size) {
    if (t <= 0 || t >= 1) return;
    final y = size.height * t;
    canvas.drawRect(
      Rect.fromLTWH(0, y - 14, size.width, 14),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withValues(alpha: 0), color.withValues(alpha: 0.18)],
        ).createShader(Rect.fromLTWH(0, y - 14, size.width, 14)),
    );
    canvas.drawLine(
      Offset(0, y),
      Offset(size.width, y),
      Paint()
        ..strokeWidth = 1
        ..color = color.withValues(alpha: 0.8),
    );
  }

  @override
  bool shouldRepaint(ScanlinePainter old) => old.t != t || old.color != color;
}

// ── Irrigation flow line ─────────────────────────────────────────────────────

/// Marching-dash line indicating active water flow. [phase] advances 0..1
/// and wraps; dashes march left → right while the actuator is ON.
class FlowLinePainter extends CustomPainter {
  final double phase;
  final Color color;
  final bool active;

  FlowLinePainter({
    required this.phase,
    this.color = AppColors.health,
    this.active = true,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2;
    if (!active) {
      canvas.drawLine(
        Offset(0, y),
        Offset(size.width, y),
        Paint()
          ..strokeWidth = 1
          ..color = AppColors.sageFaint,
      );
      return;
    }
    const dash = 8.0, gap = 6.0;
    final p = Paint()
      ..strokeWidth = 2
      ..color = color;
    var x = -((dash + gap) * (1 - phase));
    while (x < size.width) {
      final x0 = x.clamp(0.0, size.width);
      final x1 = (x + dash).clamp(0.0, size.width);
      if (x1 > x0) canvas.drawLine(Offset(x0, y), Offset(x1, y), p);
      x += dash + gap;
    }
  }

  @override
  bool shouldRepaint(FlowLinePainter old) =>
      old.phase != phase || old.active != active || old.color != color;
}

// ── Login backdrop ───────────────────────────────────────────────────────────

/// Faint technical grid with a slow drifting scan band — the login screen's
/// backdrop. Monochromatic by design (not a colorful bubble field).
class GridBackdropPainter extends CustomPainter {
  final double t; // 0..1 loop

  GridBackdropPainter({required this.t});

  @override
  void paint(Canvas canvas, Size size) {
    const cell = 48.0;
    final grid = Paint()
      ..strokeWidth = 0.5
      ..color = AppColors.sageFaint.withValues(alpha: 0.07);
    for (var x = 0.0; x <= size.width; x += cell) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }
    for (var y = 0.0; y <= size.height; y += cell) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    // Drifting horizontal scan band.
    final y = size.height * t;
    canvas.drawRect(
      Rect.fromLTWH(0, y - 60, size.width, 120),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            AppColors.health.withValues(alpha: 0),
            AppColors.health.withValues(alpha: 0.035),
            AppColors.health.withValues(alpha: 0),
          ],
        ).createShader(Rect.fromLTWH(0, y - 60, size.width, 120)),
    );
    // Brighter grid intersections inside the band.
    final dot = Paint()..color = AppColors.health.withValues(alpha: 0.12);
    for (var x = 0.0; x <= size.width; x += cell) {
      for (var gy = y - 48; gy <= y + 48; gy += cell) {
        final snapped = (gy / cell).round() * cell;
        if (snapped >= 0 && snapped <= size.height) {
          canvas.drawRect(
              Rect.fromCenter(
                  center: Offset(x, snapped.toDouble()), width: 2, height: 2),
              dot);
        }
      }
    }
  }

  @override
  bool shouldRepaint(GridBackdropPainter old) => old.t != t;
}
