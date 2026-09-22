import 'package:flutter/material.dart';

import '../theme/motion.dart';
import '../theme/tokens.dart';

/// Loading placeholder.
///
/// `shimmer` and `ShaderMask` both mask -> a mask forces `saveLayer()`, an offscreen pass per widget
/// per frame -> never one of those over a video feed on a budget SoC.
/// A sliding gradient FILL looks identical on a solid block and is an ordinary paint — no mask, no
/// offscreen buffer, no saveLayer.
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

  /// Started from [didChangeDependencies], not the field initializer: `reduceMotion` needs an
  /// InheritedWidget lookup, and a repeating ticker must never be armed before that answer exists.
  bool _motionStarted = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_motionStarted) return;
    _motionStarted = true;
    if (context.reduceMotion) {
      // Parked mid-sweep: a static sheen, the resting state of this loop. Never flat — flat reads
      // as a dead box rather than a loading one.
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

/// Slides the gradient across the box: -1 (fully left) → 2 (fully past right).
class _Sweep extends GradientTransform {
  const _Sweep(this.t);

  final double t;

  @override
  Matrix4 transform(Rect bounds, {TextDirection? textDirection}) =>
      Matrix4.translationValues(bounds.width * (t * 3 - 1), 0, 0);
}
