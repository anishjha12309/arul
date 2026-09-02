import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The hand-drawn stroke glyphs the design handoffs specify by SVG path.
///
/// Material's `Icons` set stays the default everywhere else — it costs nothing and tree-shakes.
/// These three have no Material equivalent -> painting them adds no asset and no font.
/// This API is single-[color] stroke -> a filled or two-tone glyph is artwork, kept with its control.
/// Every glyph is authored in the handoff's 24×24 viewBox and scaled to [ArulLineIcon.size].
/// Strokes scale with it -> the optical weight holds at any size.
enum ArulLineGlyph {
  /// Dock: Wallpapers. Rounded frame + small circle + mountain polyline.
  wallpapers,

  /// Dock: Ringtones. Music note — head, stem, flag.
  ringtones,

  /// Dock: Settings. Inner circle inside a dashed outer ring.
  settings,
}

/// One stroke glyph from [ArulLineGlyph], drawn in [color] at [size] square.
class ArulLineIcon extends StatelessWidget {
  const ArulLineIcon({
    super.key,
    required this.glyph,
    required this.size,
    required this.color,
  });

  final ArulLineGlyph glyph;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: _LineIconPainter(glyph: glyph, color: color),
      ),
    );
  }
}

class _LineIconPainter extends CustomPainter {
  const _LineIconPainter({required this.glyph, required this.color});

  final ArulLineGlyph glyph;
  final Color color;

  /// The authoring viewBox every path below is expressed in.
  static const double _vb = 24;

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.width / _vb;
    canvas.save();
    canvas.scale(k);

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..color = color
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;

    switch (glyph) {
      case ArulLineGlyph.wallpapers:
        _wallpapers(canvas, paint..strokeWidth = 1.5);
      case ArulLineGlyph.ringtones:
        _ringtones(canvas, paint..strokeWidth = 1.7);
      case ArulLineGlyph.settings:
        _settings(canvas, paint);
    }

    canvas.restore();
  }

  /// `rect 3.2,4.4 17.6×15.2 r3` + `circle 9,10 r1.9` + `M4.4 18.4 L10 12.8 L13.6 16.4 L16.4 13.6 L20.4 17.6`.
  void _wallpapers(Canvas canvas, Paint paint) {
    canvas
      ..drawRRect(
        RRect.fromRectAndRadius(
          const Rect.fromLTWH(3.2, 4.4, 17.6, 15.2),
          const Radius.circular(3),
        ),
        paint,
      )
      ..drawCircle(const Offset(9, 10), 1.9, paint)
      ..drawPath(
        _polyline(const [
          Offset(4.4, 18.4),
          Offset(10, 12.8),
          Offset(13.6, 16.4),
          Offset(16.4, 13.6),
          Offset(20.4, 17.6),
        ]),
        paint,
      );
  }

  /// `circle 9,17.6 r2.9` + stem `M11.9 17.6 V5.6` + flag `M11.9 5.6 C15.6 6.2 17.6 7.6 17.9 9.8`.
  void _ringtones(Canvas canvas, Paint paint) {
    canvas
      ..drawCircle(const Offset(9, 17.6), 2.9, paint)
      ..drawLine(const Offset(11.9, 17.6), const Offset(11.9, 5.6), paint)
      ..drawPath(
        Path()
          ..moveTo(11.9, 5.6)
          ..cubicTo(15.6, 6.2, 17.6, 7.6, 17.9, 9.8),
        paint,
      );
  }

  /// `circle 12,12 r3.2 sw1.5` inside `circle 12,12 r7 sw2.4 dash 1.7 3`.
  ///
  /// Flutter has no dash-array -> the outer ring is arcs of `1.7` every `4.7` of circumference.
  void _settings(Canvas canvas, Paint paint) {
    canvas.drawCircle(const Offset(12, 12), 3.2, paint..strokeWidth = 1.5);

    const centre = Offset(12, 12);
    const r = 7.0;
    const on = 1.7;
    const period = on + 3.0;
    final circumference = 2 * math.pi * r;
    final count = (circumference / period).round();
    // Re-derive the period from the ROUNDED count -> the dashes close the ring, no seam at 12 o'clock.
    final step = 2 * math.pi / count;
    final sweep = (on / circumference) * 2 * math.pi;

    paint.strokeWidth = 2.4;
    final box = Rect.fromCircle(center: centre, radius: r);
    for (var i = 0; i < count; i++) {
      canvas.drawArc(box, i * step, sweep, false, paint);
    }
  }

  static Path _polyline(List<Offset> points) {
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (final p in points.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    return path;
  }

  @override
  bool shouldRepaint(_LineIconPainter old) =>
      old.glyph != glyph || old.color != color;
}
