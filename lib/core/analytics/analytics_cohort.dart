import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Decides whether THIS install reports to PostHog at all.
///
/// Cost rationale (why a user-level gate exists at all): PostHog bills per event
/// and the free tier is 1M events/month. Divided across a large user base that
/// budget is well under one event per user per month, so no amount of trimming
/// the event LIST can ever fit inside it — `login_success` alone, fired once per
/// user, would blow it. The only lever that actually works is sending nothing at
/// all for most installs. So we sample USERS, not events.
///
/// Why user-level beats per-event sampling: event-level sampling silently
/// corrupts funnels. Thinning `wallpaper_engaged` to 10% while
/// `wallpaper_applied` stays at 100% makes the ratio between them meaningless,
/// because numerator and denominator are drawn from different populations.
/// Sampling users keeps every panel member's history COMPLETE, so funnels,
/// retention and paths are exact within the panel; only absolute counts need
/// scaling (multiply by 1 / [_rate]).
///
/// Nothing important rides on this gate:
///   * GA4 receives 100% of every event from every install, for free, and is the
///     Google Ads conversion source — ad attribution is untouched.
///   * DAU / retention / screen views come from GA4's auto-collected
///     `first_open` / `session_start` / `screen_view`.
///   * Revenue truth lives in Neon (the `subscriptions` table), which is exact.
///     Never read revenue off a sampled product-analytics tool.
class AnalyticsCohort {
  const AnalyticsCohort._();

  /// We persist the raw DRAW, not the resulting boolean. Storing the draw means
  /// widening the panel later (say 0.05 → 0.10) only ever ADDS installs and
  /// never drops one that was already reporting, so retention curves stay
  /// continuous across a rate change. A stored boolean would force a fresh draw
  /// per install and break every cohort that spans the change.
  static const _drawKey = 'analytics_posthog_cohort_draw_v1';

  /// Share of installs in the panel.
  ///
  /// **1.0 — every install reports** (2026-08-13). The 0.05 this replaced was
  /// sized for 800k MAU (a ~40,000-user panel). At the app's actual scale that
  /// arithmetic inverted: a few dozen installs × 5% is a panel of roughly ONE
  /// device, so PostHog went days at a time with no events at all and answered
  /// no question worth asking. Sampling is a cost control, and there is no cost
  /// to control until the install base is large enough to produce one.
  ///
  /// Widening is safe BY CONSTRUCTION here and that is the whole reason the draw
  /// is persisted (see [_drawKey]): raising the rate only ever ADDS installs, so
  /// no retention curve breaks at the change. Narrowing later is the one that
  /// hurts — installs whose stored draw exceeds the new rate drop out, and any
  /// cohort spanning that date is discontinuous. Revisit around 30k MAU, where
  /// ~25 events/user/month starts approaching the 1M/month free tier.
  static const _rate = 1.0;

  /// Test seam — the panel share, so tests assert the RULE (`draw < rate`)
  /// rather than a literal that changes whenever the rate is retuned.
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
  static void debugReset() => _isMember = false;
}
