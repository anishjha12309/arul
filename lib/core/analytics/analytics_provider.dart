import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../config/app_config.dart';
import 'allowlisted_analytics_service.dart';
import 'analytics_cohort.dart';
import 'analytics_service.dart';
import 'composite_analytics_service.dart';
import 'google_analytics_service.dart';
import 'meta_analytics_service.dart';
import 'posthog_analytics_service.dart';

part 'analytics_provider.g.dart';

/// The ONLY events PostHog is billed for. Default-deny — see
/// [AllowlistedAnalyticsService]. GA4 still receives every event in the app at
/// 100% for free, so anything absent here is still measurable, just not in
/// PostHog.
///
/// The bar for being on this list: a product decision rides on it. Attempts,
/// previews, screen views, engineering failures and rare account admin actions
/// are all deliberately absent — they answer questions better served by GA4
/// (volume), Crashlytics (failures) or Neon (revenue, account state).
///
/// Mirrored in Pakiza — keep both in sync. The lists differ only where the two
/// apps genuinely differ: Arul's gated-action key is `apply` (from
/// `PremiumGateAction.source`) rather than Pakiza's `wallpaper_apply`, because
/// the enum that names the gate also names the `?source=` query param. Event
/// PROPERTIES follow Arul's convention (`wallpaper_id` + `category`) — Pakiza
/// carries `type` where Arul carries `category`, since category is Arul's browse
/// axis and Pakiza has none. Public (Pakiza keeps its copy private) so
/// `test/core/analytics_gating_test.dart` can assert against the REAL list
/// instead of a duplicate literal.
/// TRIMMED to four events on 2026-07-29 (was eleven) as an explicit cost
/// decision. The filter is NOT "is it interesting" — it is "can nothing cheaper
/// answer it":
///   * GA4 receives EVERY event at 100% for free, so anything wanted purely as a
///     record belongs there, not here.
///   * Neon is authoritative for users, trials, subscriptions and referrals —
///     revenue truth is NEVER PostHog. Mirroring those here buys a second,
///     sampled, less accurate copy of a number already owned.
/// What survives is the behavioural sequence Neon cannot reconstruct: how much
/// someone browsed, whether they got value, whether the paywall stopped them,
/// and whether they then paid.
///
/// Dropped deliberately — do NOT re-add without naming the question it answers:
/// `login_success`, `trial_started`, `referral_shared` (all in Neon and GA4);
/// `wallpaper_shared`, `ringtone_set` (secondary value moments, in GA4);
/// `share_blocked_premium`, `ringtone_set_blocked_premium` (the apply gate
/// carries the volume and the funnel shape is identical).
const postHogAllowedEvents = <String>{
  // Feed engagement. ONE summary per feed session, not one per card — see
  // `_flushFeedSession` in feed_screen.dart. PostHog bills per event and not per
  // property, so a single event carrying counts answers scroll-depth and
  // live/static-mix questions at a fraction of the volume. The per-card
  // `wallpaper_engaged` that feeds these counters is deliberately NOT here: it
  // survives for GA4 only, which takes it at 100% for free. This is also the
  // highest-volume survivor, so it is the first place to look if the bill moves.
  'feed_session_ended',

  // The value moment — numerator of the only funnel that matters.
  'wallpaper_applied',

  // The paywall trigger: the moment that produces revenue. Pairs with
  // `wallpaper_applied` above and `subscription_active` below to give
  // browsed → blocked → paid with no sampling skew inside the panel.
  'apply_blocked_premium',

  // Conversion. Kept ONLY so the funnel has an endpoint inside PostHog; the
  // authoritative revenue number is always the Neon subscriptions row.
  'subscription_active',
};

/// App-wide [AnalyticsService]. Assembles the real backends from whichever keys
/// are configured, so call sites never change:
///
///   * PostHog — [postHogAllowedEvents] only, and only for the ~5% of installs
///     in the [AnalyticsCohort] panel; product analytics. Requires a real
///     `POSTHOG_KEY` AND cohort membership.
///   * Google Analytics (GA4/Firebase) — EVERY event at 100% + ★→standard
///     conversion events (login/purchase) for Google Ads — when
///     `AppConfig.firebaseEnabled` (every real build with google-services.json +
///     FIREBASE_ENABLED=true; skipped under `flutter test`). This is the
///     complete, unsampled record.
///   * Meta App Events — ★ conversion events only — when `AppConfig.metaEnabled`
///     (real App ID + client token).
///
/// If more than one is present they're wrapped in a [CompositeAnalyticsService];
/// a single one is returned directly; none → [NoOpAnalyticsService], so
/// `flutter test`, CI, and key-less dev builds send nothing.
@Riverpod(keepAlive: true)
AnalyticsService analyticsService(Ref ref) {
  // Cohort membership is resolved in main() before `Posthog().setup()` runs.
  // It defaults to false, so a build that never called `AnalyticsCohort.resolve`
  // silently sends nothing to PostHog rather than everything.
  final services = <AnalyticsService>[
    if (AppConfig.posthogEnabled && AnalyticsCohort.isMember)
      const AllowlistedAnalyticsService(
        PostHogAnalyticsService(),
        allowed: postHogAllowedEvents,
      ),
    if (AppConfig.firebaseEnabled) GoogleAnalyticsService(),
    if (AppConfig.metaEnabled) MetaAnalyticsService(),
  ];

  return switch (services.length) {
    0 => const NoOpAnalyticsService(),
    1 => services.first,
    _ => CompositeAnalyticsService(services),
  };
}
