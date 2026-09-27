import 'package:flutter/material.dart';

import '../../theme/arul_tokens.dart';
import '../theme/motion.dart';

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
    duration: ArulTokens.skeletonLoop,
  );
  // TickerMode is inherited from the route -> this parks itself when the page isn't current.

  bool _motionStarted = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_motionStarted) return;
    _motionStarted = true;
    if (context.reduceMotion) {
      _c.value = 0.5;
    } else {
      _c.repeat();
    }
  }

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
              begin: const Alignment(-1, -0.36),
              end: const Alignment(1, 0.36),
              colors: const [
                ArulTokens.skeletonBase,
                ArulTokens.skeletonHighlight,
                ArulTokens.skeletonBase,
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

class _Sweep extends GradientTransform {
  const _Sweep(this.t);

  final double t;

  @override
  Matrix4 transform(Rect bounds, {TextDirection? textDirection}) =>
      Matrix4.translationValues(bounds.width * (t * 3 - 1), 0, 0);
}
