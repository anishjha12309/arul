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
/// **Owner's list, 2026-08-18: the journey and nothing else.** Five events plus
/// `Application Installed` (captured by hand in `main.dart` — see
/// `_startPostHog`, it never passes through this list) are the whole PostHog
/// stream: install → login → trial → the two value moments → the ringtone one.
/// Everything else was noise around them and is GA4-only now. This is a
/// READABILITY decision, not a cost one — the previous eleven-event list sat far
/// inside the 1M/month free tier. Adding to the list is a decision someone makes
/// on purpose, not a cleanup.
///
/// What was dropped and where the question is answered instead:
///   * `feed_session_ended` — the highest-volume event on the old list. Scroll
///     depth and live/static mix are GA4 questions.
///   * `*_blocked_premium` (all three gates) — paywall-trigger volume, GA4.
///   * `subscription_active` — revenue truth is Neon and always was; PostHog
///     only ever held it so the funnel had an endpoint. `trial_started` is the
///     endpoint now.
///   * `referral_shared` — GA4.
/// Attempts, failures and rare account admin (`*_attempt`, `login_failed`,
/// `share_watermark_failed`, `account_delete_*`) were never here — Crashlytics,
/// GA4 and Neon questions.
///
/// The cost of the trim, stated plainly: PostHog now sees a user only when they
/// do one of these five things, so DAU/retention read there measure "did
/// something that matters", not "opened the app". Sessions still resolve (the
/// SDK's session observer is installed regardless of the lifecycle flag), and
/// GA4's `first_open`/`session_start`/`screen_view` remain the complete
/// open-the-app record.
///
/// Diverges from Pakiza on purpose as of 2026-08-18 (its list is its own four
/// cost-trimmed events at a 5% cohort). Event PROPERTIES still follow Arul's
/// convention (`wallpaper_id` + `category`). Public so
/// `test/core/analytics_gating_test.dart` can assert against the REAL list
/// instead of a duplicate literal.
const postHogAllowedEvents = <String>{
  // ── Acquisition ────────────────────────────────────────────────────────────
  // Where a cohort starts, and the event that makes the funnel resolvable
  // per-person. Pairs with `Application Installed` from `main.dart`.
  'login_success',

  // ── Value moments ──────────────────────────────────────────────────────────
  // What people came for. `wallpaper_applied` is also what orders the All feed
  // (via the server-side counter, NOT via this event — analytics is never a
  // ranking source), so its rate is worth watching directly.
  'wallpaper_applied',
  'wallpaper_shared',
  'ringtone_set',

  // ── Conversion ─────────────────────────────────────────────────────────────
  // The funnel's endpoint. The authoritative revenue number is always the Neon
  // subscriptions row — never count money here.
  'trial_started',
};

/// App-wide [AnalyticsService]. Assembles the real backends from whichever keys
/// are configured, so call sites never change:
///
///   * PostHog — [postHogAllowedEvents] only, and only for installs in the
///     [AnalyticsCohort] panel (currently all of them); product analytics.
///     Requires a real `POSTHOG_KEY` AND cohort membership. Its SDK lifecycle
///     autocapture is OFF, so the only event PostHog receives outside this list
///     is the hand-emitted `Application Installed` in `main.dart`.
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
