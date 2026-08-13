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
/// WIDENED to the full journey on 2026-08-13 (was four, trimmed there from
/// eleven on 2026-07-29). The 2026-07-29 trim was correct arithmetic against the
/// wrong scale: paired with a 5% cohort it left PostHog with roughly one
/// reporting device, which answers nothing. With the cohort at 100%
/// ([AnalyticsCohort]) the constraint that matters is the 1M/month free tier,
/// and this list plus SDK lifecycle events sits far inside it until ~30k MAU.
///
/// The bar is now what a product analytics tool is FOR — reconstructing a user's
/// path — not "can nothing cheaper answer it". Two rules still hold and are not
/// cost decisions:
///   * Revenue truth is Neon, never PostHog. `subscription_active` is here so
///     the funnel has an endpoint, not so anyone counts money with it.
///   * Per-CARD events stay out. `wallpaper_engaged` fires once per dwelled card
///     and is the single genuine volume risk in the app; `feed_session_ended`
///     already carries its counts, and GA4 takes the per-card copy at 100% free.
///
/// Still deliberately absent — attempts, failures and rare account admin
/// (`*_attempt`, `login_failed`, `share_watermark_failed`, `account_delete_*`).
/// Those are Crashlytics and GA4 questions; putting them here would make the
/// funnel harder to read, not the data richer.
const postHogAllowedEvents = <String>{
  // ── Acquisition ────────────────────────────────────────────────────────────
  // Where a cohort starts. Also in Neon and GA4, but a funnel needs its own
  // first step to be resolvable per-person inside the same tool.
  'login_success',

  // ── Engagement ─────────────────────────────────────────────────────────────
  // ONE summary per feed session, not one per card — see `_flushFeedSession` in
  // feed_screen.dart. PostHog bills per event and not per property, so a single
  // event carrying counts answers scroll-depth and live/static-mix questions at
  // a fraction of the volume. Still the highest-volume event here, so it is the
  // first place to look if the bill ever moves.
  'feed_session_ended',

  // ── Value moments ──────────────────────────────────────────────────────────
  // What people came for. `wallpaper_applied` is also what orders the All feed
  // (via the server-side counter, NOT via this event — analytics is never a
  // ranking source), so its rate is worth watching directly.
  'wallpaper_applied',
  'wallpaper_shared',
  'ringtone_set',

  // ── Paywall ────────────────────────────────────────────────────────────────
  // The moments that produce revenue. Apply carries most of the volume; share
  // and ringtone are kept now so the three gated actions can be compared against
  // each other rather than assumed to behave alike.
  'apply_blocked_premium',
  'share_blocked_premium',
  'ringtone_set_blocked_premium',

  // ── Conversion ─────────────────────────────────────────────────────────────
  // The funnel's endpoint. The authoritative revenue number is always the Neon
  // subscriptions row — never count money here.
  'trial_started',
  'subscription_active',

  // ── Referral loop ──────────────────────────────────────────────────────────
  // The outbound half of growth. Pairs with `login_success` on the receiving
  // install to make an invite → install → pay chain visible in one place.
  'referral_shared',
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
