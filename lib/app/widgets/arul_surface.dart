import 'package:flutter/material.dart';

import '../../theme/arul_palette.dart';

/// The ground every raised surface shares: sheet, dialog, toast and the preparing card. One fill
/// (lit from the top on dark), one rim, one lift, so a sheet and a dialog read as one family.
class ArulSurface extends StatelessWidget {
  const ArulSurface({
    super.key,
    required this.borderRadius,
    required this.child,
    this.padding,
    this.palette,
    this.color,
    this.rim = true,
    this.rimColor,
    this.litEdge = true,
    this.shadow,
  });

  final BorderRadius borderRadius;
  final Widget child;
  final EdgeInsetsGeometry? padding;

  /// Pins the surface to one palette (the toast is dark in both themes); null reads the theme's.
  final ArulPalette? palette;

  /// A flat fill instead of the palette's sheet ground (the premium sheets' cream).
  final Color? color;

  /// A sheet meets the screen's edges, so it draws no rim; a dialog or a toast floats and does.
  final bool rim;
  final Color? rimColor;

  /// The gold top edge, on surfaces whose palette has one.
  final bool litEdge;

  /// Overrides the palette's lift; a dark toast over a light page takes the light page's shadow.
  final List<BoxShadow>? shadow;

  @override
  Widget build(BuildContext context) {
    final p = palette ?? ArulPalette.of(context);
    final edge = litEdge && color == null ? p.litEdge : null;
    var body = padding == null
        ? child
        : Padding(padding: padding!, child: child);
    if (edge != null) {
      body = CustomPaint(
        foregroundPainter: _LitEdgePainter(
          gradient: edge,
          radius: borderRadius.topLeft.x,
        ),
        child: body,
      );
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color ?? p.sheet,
        gradient: color == null ? p.sheetGradient : null,
        borderRadius: borderRadius,
        border: rim ? Border.all(color: rimColor ?? p.rim) : null,
        boxShadow: shadow ?? p.overlayShadow,
      ),
      child: body,
    );
  }
}

/// A 1 px stroke along the rounded top edge, fading out before each corner turns down.
class _LitEdgePainter extends CustomPainter {
  const _LitEdgePainter({required this.gradient, required this.radius});

  final Gradient gradient;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    const inset = 0.5;
    final r = radius.clamp(0.0, size.shortestSide / 2);
    final path = Path()
      ..moveTo(inset, r)
      ..arcToPoint(Offset(r, inset), radius: Radius.circular(r - inset))
      ..lineTo(size.width - r, inset)
      ..arcToPoint(
        Offset(size.width - inset, r),
        radius: Radius.circular(r - inset),
      );
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..shader = gradient.createShader(Offset.zero & Size(size.width, r));
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_LitEdgePainter old) =>
      old.gradient != gradient || old.radius != radius;
}
