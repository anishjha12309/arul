// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'performance_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// App-wide [PerformanceMonitor]. Returns the real Firebase implementation in
/// every real app build (debug, profile, release), and the no-op under
/// `flutter test` — same `AppConfig.firebaseEnabled` guard as `main()` and
/// `crashReporterProvider`, so tests never touch an uninitialised SDK.

@ProviderFor(performanceMonitor)
final performanceMonitorProvider = PerformanceMonitorProvider._();

/// App-wide [PerformanceMonitor]. Returns the real Firebase implementation in
/// every real app build (debug, profile, release), and the no-op under
/// `flutter test` — same `AppConfig.firebaseEnabled` guard as `main()` and
/// `crashReporterProvider`, so tests never touch an uninitialised SDK.

final class PerformanceMonitorProvider
    extends
        $FunctionalProvider<
          PerformanceMonitor,
          PerformanceMonitor,
          PerformanceMonitor
        >
    with $Provider<PerformanceMonitor> {
  /// App-wide [PerformanceMonitor]. Returns the real Firebase implementation in
  /// every real app build (debug, profile, release), and the no-op under
  /// `flutter test` — same `AppConfig.firebaseEnabled` guard as `main()` and
  /// `crashReporterProvider`, so tests never touch an uninitialised SDK.
  PerformanceMonitorProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'performanceMonitorProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$performanceMonitorHash();

  @$internal
  @override
  $ProviderElement<PerformanceMonitor> $createElement(
    $ProviderPointer pointer,
  ) => $ProviderElement(pointer);

  @override
  PerformanceMonitor create(Ref ref) {
    return performanceMonitor(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(PerformanceMonitor value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<PerformanceMonitor>(value),
    );
  }
}

String _$performanceMonitorHash() =>
    r'791ccb6ad8f121a5e01f9ae822d53386f91408a2';
