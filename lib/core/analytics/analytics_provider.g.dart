// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'analytics_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
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

@ProviderFor(analyticsService)
final analyticsServiceProvider = AnalyticsServiceProvider._();

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

final class AnalyticsServiceProvider
    extends
        $FunctionalProvider<
          AnalyticsService,
          AnalyticsService,
          AnalyticsService
        >
    with $Provider<AnalyticsService> {
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
  AnalyticsServiceProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'analyticsServiceProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$analyticsServiceHash();

  @$internal
  @override
  $ProviderElement<AnalyticsService> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  AnalyticsService create(Ref ref) {
    return analyticsService(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(AnalyticsService value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<AnalyticsService>(value),
    );
  }
}

String _$analyticsServiceHash() => r'9a9f69a14754d46f766cd8f260538481237a5107';
