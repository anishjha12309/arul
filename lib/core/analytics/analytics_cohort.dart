import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AnalyticsCohort {
  const AnalyticsCohort._();

  static const _drawKey = 'analytics_posthog_cohort_draw_v1';

  /// Share of installs in the panel.
  ///
  /// **1.0 — every install reports.** Sampling is a cost control and there is no cost to control
  /// until the base is large: a few dozen installs × 5% is a panel of roughly ONE device, and
  /// PostHog then goes days at a time with no events at all.
  /// Widening is safe BY CONSTRUCTION — the whole reason the draw is persisted ([_drawKey]) ->
  /// raising the rate only ADDS installs, so no retention curve breaks at the change.
  /// NARROWING is the one that hurts -> installs whose stored draw exceeds the new rate drop out and
  /// any cohort spanning the change is discontinuous.
  /// Revisit near 30k MAU -> ~25 events/user/month starts approaching the 1M/month free tier.
  static const _rate = 1.0;

  /// Test seam — the panel share, so tests assert the RULE (`draw < rate`), not a retunable literal.
  @visibleForTesting
  static const double debugRate = _rate;

  /// Whether this install reports to PostHog.
  ///
  /// Defaults to **false** so that any path which forgets to call [resolve]
  /// sends nothing rather than everything — the safe direction to fail for a
  /// backend that bills per event. `flutter test` and key-less dev builds
  /// therefore stay silent without needing their own guard.
  static bool get isMember => _isMember;
  static bool _isMember = false;

  static bool get isFreshInstall => _isFreshInstall;
  static bool _isFreshInstall = false;

  static bool resolve(SharedPreferences prefs, {Random? random}) {
    var draw = prefs.getDouble(_drawKey);
    _isFreshInstall = draw == null;
    if (draw == null) {
      draw = (random ?? Random()).nextDouble();
      // Fire-and-forget: a failed write just means this install re-draws next
      // launch, which is harmless (it is still a uniform draw).
      unawaited(prefs.setDouble(_drawKey, draw));
    }
    _isMember = draw < _rate;
    return _isMember;
  }

  @visibleForTesting
  static void debugReset() {
    _isMember = false;
    _isFreshInstall = false;
  }
}
