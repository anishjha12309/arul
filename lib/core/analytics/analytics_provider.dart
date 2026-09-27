import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../config/app_config.dart';
import '../config/build_info.dart';
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
/// Public so `test/core/analytics_gating_test.dart` asserts the REAL list, not a duplicate literal.
const postHogAllowedEvents = <String>{
  // Acquisition: where a cohort starts, and what makes the funnel resolvable per-person.
  ArulEvents.loginSuccess,

  // Value moments — what people came for.
  ArulEvents.wallpaperApplied,
  ArulEvents.wallpaperShared,
  ArulEvents.ringtoneSet,

  ArulEvents.trialStarted,

  'login_cancelled',
  'login_failed',
  'login_attempt',
  'login_surface_shown',
};

/// App-wide [AnalyticsService], assembled from whichever keys are configured -> call sites never change.
///
///   * PostHog — [postHogAllowedEvents] only, for [AnalyticsCohort] members, and **only from a PLAY
///     install** ([PlayInstall]). SDK lifecycle autocapture is OFF -> the one event outside this
///     list is `Application Installed`;
///   * GA4/Firebase — EVERY event at 100% plus the ★→standard mappings; the complete, unsampled record;
///   * Meta App Events — ★ conversion events only.
///
/// Several present -> [CompositeAnalyticsService]; one -> itself; none -> [NoOpAnalyticsService].
/// So `flutter test`, CI and key-less dev builds send nothing.
@Riverpod(keepAlive: true)
AnalyticsService analyticsService(Ref ref) {
  final services = <AnalyticsService>[
    if (AppConfig.posthogEnabled &&
        AnalyticsCohort.isMember &&
        PlayInstall.isPlay)
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
