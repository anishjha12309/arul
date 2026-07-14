// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'performance_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// App-wide [PerformanceMonitor].
///
/// FIREBASE-REENABLE: currently ALWAYS the no-op because Firebase is not
/// provisioned (no google-services.json). Once it is, copy the reference's
/// `firebase_performance_monitor.dart` next to this file and restore:
///
///   if (!AppConfig.firebaseEnabled) return const NoOpPerformanceMonitor();
///   return const FirebasePerformanceMonitor();

@ProviderFor(performanceMonitor)
final performanceMonitorProvider = PerformanceMonitorProvider._();

/// App-wide [PerformanceMonitor].
///
/// FIREBASE-REENABLE: currently ALWAYS the no-op because Firebase is not
/// provisioned (no google-services.json). Once it is, copy the reference's
/// `firebase_performance_monitor.dart` next to this file and restore:
///
///   if (!AppConfig.firebaseEnabled) return const NoOpPerformanceMonitor();
///   return const FirebasePerformanceMonitor();

final class PerformanceMonitorProvider
    extends
        $FunctionalProvider<
          PerformanceMonitor,
          PerformanceMonitor,
          PerformanceMonitor
        >
    with $Provider<PerformanceMonitor> {
  /// App-wide [PerformanceMonitor].
  ///
  /// FIREBASE-REENABLE: currently ALWAYS the no-op because Firebase is not
  /// provisioned (no google-services.json). Once it is, copy the reference's
  /// `firebase_performance_monitor.dart` next to this file and restore:
  ///
  ///   if (!AppConfig.firebaseEnabled) return const NoOpPerformanceMonitor();
  ///   return const FirebasePerformanceMonitor();
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
    r'c08a36b6cc63df703fd7db55710360125384def3';
