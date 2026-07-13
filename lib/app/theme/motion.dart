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

  /// Sheets, dialogs, page-level reveals — enters decelerate, exits accelerate.
  static const enter = Durations.medium2; // 300ms
  static const enterCurve = Easing.emphasizedDecelerate;
  static const exit = Durations.short3; // 150ms
  static const exitCurve = Easing.emphasizedAccelerate;

  /// The skeleton sweep. Long and slow: a fast shimmer reads as "broken", not
  /// "loading".
  static const skeletonSweep = Duration(milliseconds: 1400);

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
