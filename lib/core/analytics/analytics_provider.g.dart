// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'analytics_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// App-wide [AnalyticsService], assembled from whichever keys are configured -> call sites never change.
///
///   * PostHog — [postHogAllowedEvents] only, and only for [AnalyticsCohort] members. SDK lifecycle
///     autocapture is OFF -> the one event outside this list is `Application Installed`;
///   * GA4/Firebase — EVERY event at 100% plus the ★→standard mappings; the complete, unsampled record;
///   * Meta App Events — ★ conversion events only.
///
/// Several present -> [CompositeAnalyticsService]; one -> itself; none -> [NoOpAnalyticsService].
/// So `flutter test`, CI and key-less dev builds send nothing.

@ProviderFor(analyticsService)
final analyticsServiceProvider = AnalyticsServiceProvider._();

/// App-wide [AnalyticsService], assembled from whichever keys are configured -> call sites never change.
///
///   * PostHog — [postHogAllowedEvents] only, and only for [AnalyticsCohort] members. SDK lifecycle
///     autocapture is OFF -> the one event outside this list is `Application Installed`;
///   * GA4/Firebase — EVERY event at 100% plus the ★→standard mappings; the complete, unsampled record;
///   * Meta App Events — ★ conversion events only.
///
/// Several present -> [CompositeAnalyticsService]; one -> itself; none -> [NoOpAnalyticsService].
/// So `flutter test`, CI and key-less dev builds send nothing.

final class AnalyticsServiceProvider
    extends
        $FunctionalProvider<
          AnalyticsService,
          AnalyticsService,
          AnalyticsService
        >
    with $Provider<AnalyticsService> {
  /// App-wide [AnalyticsService], assembled from whichever keys are configured -> call sites never change.
  ///
  ///   * PostHog — [postHogAllowedEvents] only, and only for [AnalyticsCohort] members. SDK lifecycle
  ///     autocapture is OFF -> the one event outside this list is `Application Installed`;
  ///   * GA4/Firebase — EVERY event at 100% plus the ★→standard mappings; the complete, unsampled record;
  ///   * Meta App Events — ★ conversion events only.
  ///
  /// Several present -> [CompositeAnalyticsService]; one -> itself; none -> [NoOpAnalyticsService].
  /// So `flutter test`, CI and key-less dev builds send nothing.
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
