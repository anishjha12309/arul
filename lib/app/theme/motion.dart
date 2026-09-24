import 'package:flutter/material.dart';

import '../../core/config/build_info.dart';

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

  /// An image arriving from cache or the network, and the live texture over its poster. 180ms —
  /// short enough that a cached poster reads as "already there", long enough that a decoded one
  /// never pops.
  static const imageFade = Duration(milliseconds: 180);

  /// The dip a button makes under the finger. Quicker than [quick]: it must read as the press
  /// itself, not as a state change that followed it.
  static const pressDip = Duration(milliseconds: 90);

  /// Something arriving in the periphery — the end-of-feed mark breathing in behind the last card.
  /// A breath, not a flip; nothing the eye is waiting on.
  static const breathe = Duration(milliseconds: 350);

  /// The alternating loops: a flame's sway, an empty state's pulse, the Earn parcel's rattle.
  /// Ease-in-out both ways, so the turn at each end is soft.
  static const swayCurve = Curves.easeInOut;

  /// The skeleton sliding-gradient loop. The spec: 1.8s linear.
  static const skeletonSweep = Duration(milliseconds: 1800);

  /// Splash hairline loader loop. The spec: 1.6s linear.
  static const hairlineSweep = Duration(milliseconds: 1600);

  /// One full in-and-out of the feed's first-load pulse.
  static const loadingPulse = Duration(seconds: 2);

  /// One Earn-button wiggle, and the rest between wiggles.
  static const wiggle = Duration(milliseconds: 550);
  static const wiggleGap = Duration(seconds: 3);

  /// Press feedback on the primary CTA — the ONE place a physical overshoot earns its controller.
  /// `withDurationAndBounce` is the duration+bounce model -> drive it with a SpringSimulation
  /// through `AnimationController.animateWith`.

  static final press = SpringDescription.withDurationAndBounce(
    duration: const Duration(milliseconds: 320),
    bounce: 0.28,
  );
}

/// Whether this frame should hold still.
///
/// TWO signals, one answer:
///   - `MediaQuery.disableAnimations` — the accessibility setting AND Android's battery saver,
///     which is where most of the real traffic comes from;
///   - [DeviceTier.low] — a 2–3 GB two-decoder phone, where every repainting pixel competes with
///     the video decoder for the same budget.
///
/// **Animations HOLD at their resting state, they are not removed.** A skeleton parks its sheen
/// mid-sweep rather than going flat, a sheet sits at its settled offset rather than at +24, a press
/// scale stays at 1. Nothing moves position when the flag flips, so a phone that turns battery
/// saver on mid-session sees stillness, never a re-layout.
///
/// The tier half is read from the resolved static, not watched: the probe lands inside the splash,
/// before any animated screen builds, and a tier cannot change while the process lives.
extension ReduceMotion on BuildContext {
  bool get reduceMotion =>
      (MediaQuery.maybeDisableAnimationsOf(this) ?? false) ||
      DeviceQuality.resolved == DeviceTier.low;
}
