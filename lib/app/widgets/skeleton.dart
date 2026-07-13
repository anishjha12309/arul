import 'package:flutter/material.dart';

import '../theme/motion.dart';
import '../theme/tokens.dart';

/// Loading placeholder.
///
/// Deliberately NOT the `shimmer` package, and not `ShaderMask`: both mask, and
/// a mask forces `saveLayer()` — a full offscreen render pass, every frame, per
/// shimmering widget. Over a video feed on a budget SoC that is exactly the
/// wrong tax.
///
/// A sliding gradient FILL is visually identical on a solid block and is an
/// ordinary paint: no mask, no offscreen buffer, no saveLayer.
class Skeleton extends StatefulWidget {
  const Skeleton({
    super.key,
    this.borderRadius = Radii.cardShape,
    this.onMedia = false,
  });

  final BorderRadius borderRadius;

  /// True when this skeleton sits over full-bleed media (the viewer), where it
  /// must stay dark in BOTH themes — a light skeleton would flash white against
  /// a wallpaper. False in the grid, where it is a placeholder ON a surface and
  /// must follow the theme: a hardcoded dark block is a hole punched in an ivory
  /// screen.
  final bool onMedia;

  @override
  State<Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<Skeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: Motion.skeletonSweep,
  )..repeat();
  // TickerMode (inherited from the route) already parks this controller when the
  // page isn't current, so a backgrounded feed page stops requesting frames.

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final base = widget.onMedia
        ? ArulColors.inkRaised
        : scheme.surfaceContainerHighest;
    // The sweep is a lift toward the brand hue, not toward white: a white sweep
    // on ivory is invisible, and on ink it flashes.
    final hi = Color.lerp(base, scheme.primary, 0.22)!;
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) => DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: widget.borderRadius,
            gradient: LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: [base, hi, base],
              stops: const [0.0, 0.5, 1.0],
              transform: _Sweep(_c.value),
            ),
          ),
        ),
      ),
    );
  }
}

/// Slides the gradient across the box: -1 (fully left) → 2 (fully past right).
class _Sweep extends GradientTransform {
  const _Sweep(this.t);

  final double t;

  @override
  Matrix4 transform(Rect bounds, {TextDirection? textDirection}) =>
      Matrix4.translationValues(bounds.width * (t * 3 - 1), 0, 0);
}
