import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Decides whether THIS install reports to PostHog at all.
///
/// PostHog bills per event on a 1M/month free tier -> across a large base that is under one event
/// per user per month -> no trimming of the event LIST can ever fit (`login_success` alone, once per
/// user, would blow it) -> sample USERS, not events.
/// Event-level sampling corrupts funnels — thin `wallpaper_engaged` to 10% against a 100%
/// `wallpaper_applied` and the ratio is meaningless, numerator and denominator drawn from different
/// populations -> sampling users keeps each member's history COMPLETE, so funnels, retention and
/// paths are exact within the panel and only absolute counts need scaling (× 1 / [_rate]).
///
/// Nothing important rides on this gate:
///   * GA4 takes 100% of every event from every install, free, and is the Google Ads conversion
///     source -> ad attribution is untouched.
///   * DAU / retention / screen views come from GA4's auto-collected `first_open` /
///     `session_start` / `screen_view`.
///   * Revenue truth is Neon (`subscriptions`), which is exact -> NEVER read revenue off a sampled
///     product-analytics tool.
class AnalyticsCohort {
  const AnalyticsCohort._();

  /// Persist the raw DRAW, never the resulting boolean -> widening the panel later only ever ADDS
  /// installs and drops none that already reported, so retention curves stay continuous across a
  /// rate change; a stored boolean forces a fresh draw and breaks every cohort spanning it.
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

  /// Whether [resolve] had to CREATE this install's draw — i.e. no launch ever
  /// wrote one before, which makes this launch the install itself.
  ///
  /// `main()` uses it to emit `Application Installed` by hand, because the SDK's
  /// lifecycle autocapture is off (it is all-or-nothing and also fires
  /// `Application Opened`/`Backgrounded` every launch). The persisted draw is
  /// already this app's one durable first-launch marker, so it answers the
  /// question directly; a second prefs key for the same fact could only drift
  /// away from it. Same failure mode as the SDK's own integration — a prefs
  /// write that never lands re-draws next launch and re-fires.
  ///
  /// False until [resolve] runs, and false for every install that launched
  /// before this flag existed (their draw is already on disk), so shipping it
  /// cannot back-date an install event onto the existing base.
  static bool get isFreshInstall => _isFreshInstall;
  static bool _isFreshInstall = false;

  /// Draws once per install and caches the answer for the process lifetime.
  ///
  /// MUST run before `Posthog().setup()`. The gate is deliberately placed ABOVE
  /// the SDK rather than inside an [AnalyticsService] decorator, because the SDK
  /// autocaptures its own lifecycle events (`Application Opened`,
  /// `Application Backgrounded`, `Application Installed`, `Application Updated`)
  /// which never pass through our `track()` path and so cannot be filtered
  /// anywhere downstream. Skipping `setup()` entirely is the only thing that
  /// stops them — and it also means a non-panel device does zero PostHog
  /// network, native-init and battery work, which matters on the budget phones
  /// this app targets.
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

  /// Test seam — clears the process-level cache between tests.
  @visibleForTesting
  static void debugReset() {
    _isMember = false;
    _isFreshInstall = false;
  }
}
