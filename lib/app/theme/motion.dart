import 'package:flutter/material.dart';

import '../../core/config/build_info.dart';

/// `Easing` and `Durations` are Material's own M3 tokens and ARE in stable -> use them, not hand cubics.
abstract final class Motion {
  static const quick = Durations.short4;
  static const quickCurve = Easing.standard;

  static const enter = Duration(milliseconds: 300);
  static const enterCurve = Curves.ease;

  /// A sheet or dialog arriving: most of the travel lands in the first hundred milliseconds, then a
  /// long settle — quick to answer the tap, slow to land.
  static const overlayIn = Durations.medium4;
  static const overlayInCurve = Easing.emphasizedDecelerate;

  /// Leaving takes half the entrance and accelerates away: a closed thing gets out of the way.
  static const overlayOut = Durations.short4;
  static const overlayOutCurve = Easing.emphasizedAccelerate;

  /// The ONLY motion a sheet makes is its route's rise. A second fade inside the sheet sent the
  /// whole sheet through an offscreen layer on every frame of it.
  static const sheet = AnimationStyle(
    duration: overlayIn,
    reverseDuration: overlayOut,
    curve: overlayInCurve,
    reverseCurve: overlayOutCurve,
  );

  /// A dialog travels nowhere, so it takes less time than a sheet: a fade and a small grow.
  static const dialogIn = Durations.medium2;
  static const dialogScaleFrom = 0.94;

  /// A toast rises this far into place and sinks back out.
  static const toastIn = Durations.medium3;
  static const toastRise = 16.0;

  /// Material's floor for a message with no action; a long line earns reading time up to the cap.
  static const toastHold = Duration(seconds: 4);
  static const toastHoldMax = Duration(seconds: 8);
  static const toastReadPerChar = Duration(milliseconds: 50);

  static const exit = Duration(milliseconds: 150);
  static const exitCurve = Easing.emphasizedAccelerate;

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

  static const swayCurve = Curves.easeInOut;

  static const skeletonSweep = Duration(milliseconds: 1800);

  static const hairlineSweep = Duration(milliseconds: 1600);

  static const loadingPulse = Duration(seconds: 2);

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
/// TWO signals, one answer:
///   - `MediaQuery.disableAnimations` — Android's Remove animations (transition scale 0). Battery
///     Saver does not set it on every ROM (Nothing OS 16 leaves the scales at 1);
///   - [DeviceTier.low] — a 2–3 GB two-decoder phone, where every repainting pixel competes with
///     the video decoder for the same budget.
/// The tier half is read from the resolved static, not watched: the probe lands inside the splash,
/// before any animated screen builds, and a tier cannot change while the process lives.
extension ReduceMotion on BuildContext {
  bool get reduceMotion =>
      (MediaQuery.maybeDisableAnimationsOf(this) ?? false) ||
      DeviceQuality.resolved == DeviceTier.low;
}
