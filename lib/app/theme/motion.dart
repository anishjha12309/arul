import 'package:flutter/material.dart';

/// Motion vocabulary.
///
/// `Easing` and `Durations` are Material's own M3 motion tokens and ARE in
/// stable — use them rather than hand-rolled cubics, so timing stays consistent
/// with the platform. (Material 3 *Expressive* — its spring-motion system and
/// component set — is NOT in Flutter stable; Material is frozen at 3.44 and M3E
/// is deferred to a `material_ui` package that is still a v0.0.1 placeholder. So
/// "expressive" here is our own restraint + spring, not an M3E import.)
abstract final class Motion {
  /// Chip select, toggle, small state flips.
  static const quick = Durations.short4; // 200ms
  static const quickCurve = Easing.standard;

  /// Sheets & page-level reveals (translateY(24)+fade). README: sheets .3s ease.
  static const enter = Duration(milliseconds: 300);
  static const enterCurve = Curves.ease;

  /// Dialog entrance. README: dialogs .25s.
  static const dialogEnter = Duration(milliseconds: 250);

  /// Chrome recede while swiping the feed. README: out 150ms.
  static const exit = Duration(milliseconds: 150);
  static const exitCurve = Easing.emphasizedAccelerate;

  /// Chrome settle on release. README: in 250ms ease-out.
  static const settle = Duration(milliseconds: 250);
  static const settleCurve = Curves.easeOut;

  /// Premium-nudge auto-dismiss. README: ~2.6s.
  static const nudgeAutoDismiss = Duration(milliseconds: 2600);

  /// The skeleton sliding-gradient loop. README: 1.8s linear.
  static const skeletonSweep = Duration(milliseconds: 1800);

  /// Splash hairline loader loop. README: 1.6s linear.
  static const hairlineSweep = Duration(milliseconds: 1600);

  /// Press feedback on the primary CTA. A spring, not a curve — this is the one
  /// place a physical overshoot is worth the extra controller.
  ///
  /// `SpringDescription.withDurationAndBounce` is the duration+bounce model
  /// (Flutter 3.32+); drive it with a SpringSimulation via
  /// `AnimationController.animateWith`.
  static final press = SpringDescription.withDurationAndBounce(
    duration: const Duration(milliseconds: 320),
    bounce: 0.28,
  );
}
