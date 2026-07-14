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

@ProviderFor(analyticsService)
final analyticsServiceProvider = AnalyticsServiceProvider._();

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

String _$analyticsServiceHash() => r'3260600583491e1190ddb620969bdf50f04b9d91';
