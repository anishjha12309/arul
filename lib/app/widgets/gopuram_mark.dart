import 'package:flutter/material.dart';

/// The Arul gopuram (temple-tower) logo mark.
///
/// Draws the five stacked tiers from the design handoff's SVG (viewBox
/// `0 0 44 40`) — a placeholder for the real fixed launcher mark, at the sizes
/// and placements the design specifies. Gold `#D4A017` on dark, maroon `#7A1E33`
/// on light (the caller supplies [color]).
///
/// [size] is the WIDTH in logical pixels (the 44-unit viewBox axis); height is
/// `size * 40 / 44`, preserving the source aspect ratio.
class GopuramMark extends StatelessWidget {
  const GopuramMark({super.key, required this.size, required this.color});

  /// Width in logical pixels (maps to the 44-unit viewBox width).
  final double size;

  final Color color;

  static const double _vbW = 44;
  static const double _vbH = 40;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size * _vbH / _vbW,
      child: CustomPaint(painter: _GopuramPainter(color)),
    );
  }
}

class _GopuramPainter extends CustomPainter {
  const _GopuramPainter(this.color);

  final Color color;

  // The five subpaths of the viewBox-0-0-44-40 mark, as vertex lists.
  static const List<List<Offset>> _tiers = [
    // M20 0h4v3h-4z  — the finial
    [Offset(20, 0), Offset(24, 0), Offset(24, 3), Offset(20, 3)],
    // M14 5h16l-2 5H16z
    [Offset(14, 5), Offset(30, 5), Offset(28, 10), Offset(16, 10)],
    // M10 12h24l-2.5 6H12.5z
    [Offset(10, 12), Offset(34, 12), Offset(31.5, 18), Offset(12.5, 18)],
    // M6 20h32l-3 7H9z
    [Offset(6, 20), Offset(38, 20), Offset(35, 27), Offset(9, 27)],
    // M2 29h40l-2 8H4z
    [Offset(2, 29), Offset(42, 29), Offset(40, 37), Offset(4, 37)],
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / GopuramMark._vbW;
    final sy = size.height / GopuramMark._vbH;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

    final path = Path();
    for (final tier in _tiers) {
      path.moveTo(tier.first.dx * sx, tier.first.dy * sy);
      for (final p in tier.skip(1)) {
        path.lineTo(p.dx * sx, p.dy * sy);
      }
      path.close();
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_GopuramPainter old) => old.color != color;
}
