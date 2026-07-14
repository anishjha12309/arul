import 'package:flutter/material.dart';

import '../theme/scrims.dart';
import '../theme/tokens.dart';

/// Silk ground, oil-lamp glow, kolam dot lattice, gopuram skyline.
///
/// `shouldRepaint => false` — rasterises once, never repaints, so animated
/// foreground content over it costs nothing extra. Painted rather than shipped as
/// a PNG: resolution-free, themeable, ~0 bytes of asset.
class KolamPainter extends CustomPainter {
  const KolamPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..shader = ArulScrims.silk.createShader(rect));

    final glow = Offset(size.width * 0.5, size.height * 0.72); // the lamp
    canvas.drawCircle(
      glow,
      size.width * 0.7,
      Paint()
        ..shader = RadialGradient(
          colors: [
            ArulColors.gold.withValues(alpha: 0.20),
            ArulColors.gold.withValues(alpha: 0.0),
          ],
        ).createShader(Rect.fromCircle(center: glow, radius: size.width * 0.7)),
    );

    _kolamDots(canvas, size);

    final ink = Paint()..color = ArulColors.ink.withValues(alpha: 0.92);
    final rim = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = ArulColors.gold.withValues(alpha: 0.30);

    final h = size.height;
    final w = size.width;
    final centre = _gopuram(w * 0.5, h, w * 0.46, h * 0.24, 5);
    canvas
      ..drawPath(_gopuram(w * 0.17, h, w * 0.34, h * 0.15, 4), ink)
      ..drawPath(_gopuram(w * 0.85, h, w * 0.30, h * 0.13, 4), ink)
      ..drawPath(centre, ink)
      ..drawPath(centre, rim);
  }

  /// Kolam pulli — the dot lattice a kolam is drawn around. Staggered, not
  /// square, and fading downward so it never fights the skyline.
  void _kolamDots(Canvas canvas, Size size) {
    const spacing = 30.0;
    final paint = Paint();
    final limit = size.height * 0.78;
    for (var y = spacing; y < limit; y += spacing) {
      final fade = (1 - (y / limit)).clamp(0.0, 1.0);
      paint.color = ArulColors.goldSoft.withValues(alpha: 0.16 * fade);
      final shift = (y / spacing).round().isEven ? 0.0 : spacing / 2;
      for (var x = spacing / 2 + shift; x < size.width; x += spacing) {
        canvas.drawCircle(Offset(x, y), 1.6, paint);
      }
    }
  }

  /// Stepped temple tower, mirrored about [cx].
  Path _gopuram(double cx, double baseY, double w, double h, int steps) {
    final half = w / 2;
    final stepH = h / (steps + 1);
    final inset = (half * 0.62) / steps;

    final left = <Offset>[];
    var x = cx - half;
    var y = baseY;
    left.add(Offset(x, y));
    for (var i = 0; i < steps; i++) {
      y -= stepH;
      left.add(Offset(x, y));
      x += inset;
      left.add(Offset(x, y));
    }

    final path = Path()..moveTo(left.first.dx, left.first.dy);
    for (final p in left.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    path.lineTo(cx, y - stepH); // apex
    for (final p in left.reversed) {
      path.lineTo(2 * cx - p.dx, p.dy); // mirror
    }
    return path..close();
  }

  @override
  bool shouldRepaint(KolamPainter oldDelegate) => false;
}
