import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../config/app_config.dart';
import 'allowlisted_analytics_service.dart';
import 'analytics_cohort.dart';
import 'analytics_events.dart';
import 'analytics_service.dart';
import 'composite_analytics_service.dart';
import 'google_analytics_service.dart';
import 'meta_analytics_service.dart';
import 'posthog_analytics_service.dart';

part 'analytics_provider.g.dart';

/// The ONLY events PostHog is billed for. Default-deny — see [AllowlistedAnalyticsService].
///
/// GA4 receives every event at 100% for free -> anything absent here is still measurable.
/// **Owner's list: the journey and nothing else** — install → login → trial → the value moments.
/// `Application Installed` is captured by hand in `main.dart` and never passes through this list.
/// A READABILITY decision, not a cost one -> adding to the list is deliberate, never a cleanup.
///
/// Dropped, and where the question is answered instead:
///   * `feed_session_ended` — scroll depth and live/static mix are GA4 questions;
///   * `*_blocked_premium` (all three gates) — paywall-trigger volume, GA4;
///   * `subscription_active` — revenue truth is Neon; the WORKER captures the trial→paid settle
///     server-side (workers/src/lib/posthog.ts), because that settle is app-closed;
///   * `referral_shared` — GA4.
///
/// The client-observable `subscription_active` (a repeat subscriber paying at setup) stays GA4/Meta.
/// Attempts, failures and account admin were never here — Crashlytics, GA4 and Neon questions.
/// PostHog now sees a user only on these events -> DAU there means "did something", not "opened it".
/// Sessions still resolve, and GA4's `first_open`/`session_start` remain the open-the-app record.
/// Diverges from Pakiza on purpose; properties still follow Arul's `wallpaper_id` + `category`.
/// Public so `test/core/analytics_gating_test.dart` asserts the REAL list, not a duplicate literal.
const postHogAllowedEvents = <String>{
  // Acquisition: where a cohort starts, and what makes the funnel resolvable per-person.
  ArulEvents.loginSuccess,

  // Value moments — what people came for.
  // The feed is ordered by the server-side apply counter, NEVER by this event — analytics never ranks.
  ArulEvents.wallpaperApplied,
  ArulEvents.wallpaperShared,
  ArulEvents.ringtoneSet,

  // Conversion, the funnel's endpoint. The authoritative revenue number is the Neon row, never this.
  ArulEvents.trialStarted,

  // TEMPORARY diagnostics for the sign-in wall — remove once the diagnosis is done.
  // These carry `ms_since_authenticate`/`gis_code` -> a real dismissal (seconds) splits from a
  // post-selection failure the plugin also reports as "cancelled".
  // GA4 has them too but its custom dimensions lag ~48h -> PostHog reads same-day, split by $app_build.
  // The pinned set in test/core/analytics_gating_test.dart makes removing them a deliberate edit.
  'login_cancelled',
  'login_failed',
};

/// App-wide [AnalyticsService], assembled from whichever keys are configured -> call sites never change.
///
///   * PostHog — [postHogAllowedEvents] only, and only for [AnalyticsCohort] members. SDK lifecycle
///     autocapture is OFF -> the one event outside this list is `Application Installed`;
///   * GA4/Firebase — EVERY event at 100% plus the ★→standard mappings; the complete, unsampled record;
///   * Meta App Events — ★ conversion events only.
///
/// Several present -> [CompositeAnalyticsService]; one -> itself; none -> [NoOpAnalyticsService].
/// So `flutter test`, CI and key-less dev builds send nothing.
@Riverpod(keepAlive: true)
AnalyticsService analyticsService(Ref ref) {
  // Cohort membership is resolved in main() before `Posthog().setup()`, and defaults to FALSE.
  // So a build that never called `AnalyticsCohort.resolve` sends nothing, rather than everything.
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
