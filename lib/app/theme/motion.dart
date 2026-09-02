import 'package:flutter/material.dart';

/// Motion vocabulary.
///
/// `Easing` and `Durations` are Material's own M3 tokens and ARE in stable -> use them, not hand cubics.
/// Material 3 *Expressive* is NOT in Flutter stable — it is deferred to a placeholder `material_ui`.
/// So "expressive" here is our own restraint plus spring -> never import M3E.
abstract final class Motion {
  /// Chip select, toggle, small state flips.
  static const quick = Durations.short4; // 200ms
  static const quickCurve = Easing.standard;

  /// Sheets & page-level reveals (translateY(24)+fade). The spec: sheets .3s ease.
  static const enter = Duration(milliseconds: 300);
  static const enterCurve = Curves.ease;

  /// Dialog entrance. The spec: dialogs .25s.
  static const dialogEnter = Duration(milliseconds: 250);

  /// Chrome recede while swiping the feed. The spec: out 150ms.
  static const exit = Duration(milliseconds: 150);
  static const exitCurve = Easing.emphasizedAccelerate;

  /// Chrome settle on release. The spec: in 250ms ease-out.
  static const settle = Duration(milliseconds: 250);
  static const settleCurve = Curves.easeOut;

  /// The skeleton sliding-gradient loop. The spec: 1.8s linear.
  static const skeletonSweep = Duration(milliseconds: 1800);

  /// Splash hairline loader loop. The spec: 1.6s linear.
  static const hairlineSweep = Duration(milliseconds: 1600);

  /// Press feedback on the primary CTA — the ONE place a physical overshoot earns its controller.
  /// `withDurationAndBounce` is the duration+bounce model -> drive it with a SpringSimulation
  /// through `AnimationController.animateWith`.

  static final press = SpringDescription.withDurationAndBounce(
    duration: const Duration(milliseconds: 320),
    bounce: 0.28,
  );
}
