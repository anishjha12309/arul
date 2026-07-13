import 'package:flutter/material.dart';

import 'kolam_painter.dart';

/// Brand surface for splash + sign-in. See [KolamPainter].
class KolamBackground extends StatelessWidget {
  const KolamBackground({super.key, this.child});

  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        painter: const KolamPainter(),
        isComplex: true,
        willChange: false,
        child: child,
      ),
    );
  }
}
