import 'package:flutter/material.dart';

import '../theme/motion.dart';
import '../theme/tokens.dart';

class Skeleton extends StatefulWidget {
  const Skeleton({
    super.key,
    this.borderRadius = Radii.cardShape,
    this.onMedia = false,
  });

  final BorderRadius borderRadius;

  /// True over full-bleed media (the viewer) -> stay dark in BOTH themes, or it flashes white
  /// against a wallpaper.
  /// False on a surface (the grid) -> follow the theme, or a hardcoded dark block punches a hole in
  /// the ivory screen.
  final bool onMedia;

  @override
  State<Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<Skeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: Motion.skeletonSweep,
  );
  // TickerMode from the route already parks this controller off-page -> a backgrounded feed page
  // requests no frames.

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
    final scheme = Theme.of(context).colorScheme;
    // Over media the sweep stays dark-on-dark, never a coloured flash -> on a surface it follows the
    // theme and lifts toward the brand hue.
    final base = widget.onMedia
        ? ArulColors.ink
        : scheme.surfaceContainerHighest;
    final hi = widget.onMedia
        ? ArulColors.inkVariant
        : Color.lerp(base, scheme.primary, 0.22)!;
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

class _Sweep extends GradientTransform {
  const _Sweep(this.t);

  final double t;

  @override
  Matrix4 transform(Rect bounds, {TextDirection? textDirection}) =>
      Matrix4.translationValues(bounds.width * (t * 3 - 1), 0, 0);
}
