import 'package:flutter/material.dart';

import '../../theme/arul_tokens.dart';

/// Sliding-gradient skeleton, per the spec: `110deg #14090C 30% → #2A1218 50% → #14090C 70%`,
/// background-size 200%, 1.8s linear loop.
///
/// A `ShaderMask` / masked shimmer forces `saveLayer()` — a full offscreen pass, every frame, per
/// widget -> exactly the wrong tax over a video feed on a budget SoC -> slide an ordinary gradient
/// FILL (via [GradientTransform]) instead: no mask, no offscreen buffer, no saveLayer.
/// Fixed dark palette in BOTH themes -> a skeleton over full-bleed media must never flash white.
/// An on-surface placeholder that follows the theme -> use the legacy [Skeleton] in skeleton.dart.
class SlidingSkeleton extends StatefulWidget {
  const SlidingSkeleton({super.key, this.borderRadius = BorderRadius.zero});

  final BorderRadius borderRadius;

  @override
  State<SlidingSkeleton> createState() => _SlidingSkeletonState();
}

class _SlidingSkeletonState extends State<SlidingSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: ArulTokens.skeletonLoop, // 1.8s
  )..repeat();
  // TickerMode is inherited from the route -> this parks itself when the page isn't current.

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) => DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: widget.borderRadius,
            gradient: LinearGradient(
              // 110deg ≈ a mostly-horizontal diagonal.
              begin: const Alignment(-1, -0.36),
              end: const Alignment(1, 0.36),
              colors: const [
                ArulTokens.skeletonBase, // #14090C @ 30%
                ArulTokens.skeletonHighlight, // #2A1218 @ 50%
                ArulTokens.skeletonBase, // #14090C @ 70%
              ],
              stops: const [0.30, 0.50, 0.70],
              transform: _Sweep(_c.value),
            ),
          ),
        ),
      ),
    );
  }
}

/// Slides the gradient -1 (fully left) → 2 (fully past right) -> the background-size:200% travel the
/// spec calls for.
class _Sweep extends GradientTransform {
  const _Sweep(this.t);

  final double t;

  @override
  Matrix4 transform(Rect bounds, {TextDirection? textDirection}) =>
      Matrix4.translationValues(bounds.width * (t * 3 - 1), 0, 0);
}
