// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'crash_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// App-wide [CrashReporter].
///
/// FIREBASE-REENABLE: currently ALWAYS the no-op because Firebase is not
/// provisioned (no google-services.json). Once it is, copy the reference's
/// `firebase_crash_reporter.dart` next to this file and restore:
///
///   if (!AppConfig.firebaseEnabled) return const NoOpCrashReporter();
///   return const FirebaseCrashReporter();
///
/// Call sites depend only on [CrashReporter], so nothing else changes.

@ProviderFor(crashReporter)
final crashReporterProvider = CrashReporterProvider._();

/// App-wide [CrashReporter].
///
/// FIREBASE-REENABLE: currently ALWAYS the no-op because Firebase is not
/// provisioned (no google-services.json). Once it is, copy the reference's
/// `firebase_crash_reporter.dart` next to this file and restore:
///
///   if (!AppConfig.firebaseEnabled) return const NoOpCrashReporter();
///   return const FirebaseCrashReporter();
///
/// Call sites depend only on [CrashReporter], so nothing else changes.

final class CrashReporterProvider
    extends $FunctionalProvider<CrashReporter, CrashReporter, CrashReporter>
    with $Provider<CrashReporter> {
  /// App-wide [CrashReporter].
  ///
  /// FIREBASE-REENABLE: currently ALWAYS the no-op because Firebase is not
  /// provisioned (no google-services.json). Once it is, copy the reference's
  /// `firebase_crash_reporter.dart` next to this file and restore:
  ///
  ///   if (!AppConfig.firebaseEnabled) return const NoOpCrashReporter();
  ///   return const FirebaseCrashReporter();
  ///
  /// Call sites depend only on [CrashReporter], so nothing else changes.
  CrashReporterProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'crashReporterProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$crashReporterHash();

  @$internal
  @override
  $ProviderElement<CrashReporter> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  CrashReporter create(Ref ref) {
    return crashReporter(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(CrashReporter value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<CrashReporter>(value),
    );
  }
}

String _$crashReporterHash() => r'113adf5aaf2541ae5b7b9a518cb7673ead82ce41';
