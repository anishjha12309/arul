import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../config/app_config.dart';
import 'analytics_service.dart';
import 'composite_analytics_service.dart';
import 'meta_analytics_service.dart';
import 'posthog_analytics_service.dart';

part 'analytics_provider.g.dart';

/// App-wide [AnalyticsService]. Assembles the real backends from whichever keys
/// are configured, so call sites never change:
///
///   * PostHog — all events; product analytics — when `POSTHOG_KEY` is real.
///   * Meta App Events — ★ conversion events only — when `AppConfig.metaEnabled`
///     (real App ID + client token).
///
/// FIREBASE-REENABLE: the reference also adds `GoogleAnalyticsService()` (GA4 —
/// all events + ★→login/purchase for Google Ads) when
/// `AppConfig.firebaseEnabled`. Copy `google_analytics_service.dart` from the
/// reference and add `if (AppConfig.firebaseEnabled) GoogleAnalyticsService(),`
/// once google-services.json exists.
///
/// If more than one is present they're wrapped in a [CompositeAnalyticsService];
/// a single one is returned directly; none → [NoOpAnalyticsService], so
/// `flutter test`, CI, and key-less dev builds send nothing.
@Riverpod(keepAlive: true)
AnalyticsService analyticsService(Ref ref) {
  final services = <AnalyticsService>[
    if (AppConfig.posthogEnabled) const PostHogAnalyticsService(),
    if (AppConfig.metaEnabled) MetaAnalyticsService(),
  ];

  return switch (services.length) {
    0 => const NoOpAnalyticsService(),
    1 => services.first,
    _ => CompositeAnalyticsService(services),
  };
}
