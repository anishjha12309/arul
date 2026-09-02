// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'crash_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// App-wide [CrashReporter] — real Crashlytics in every real build, the no-op under `flutter test`.
///
/// `main()` only initialises Crashlytics when `AppConfig.firebaseEnabled` -> the same guard here
/// keeps tests and unprovisioned builds off an uninitialised SDK.

@ProviderFor(crashReporter)
final crashReporterProvider = CrashReporterProvider._();

/// App-wide [CrashReporter] — real Crashlytics in every real build, the no-op under `flutter test`.
///
/// `main()` only initialises Crashlytics when `AppConfig.firebaseEnabled` -> the same guard here
/// keeps tests and unprovisioned builds off an uninitialised SDK.

final class CrashReporterProvider
    extends $FunctionalProvider<CrashReporter, CrashReporter, CrashReporter>
    with $Provider<CrashReporter> {
  /// App-wide [CrashReporter] — real Crashlytics in every real build, the no-op under `flutter test`.
  ///
  /// `main()` only initialises Crashlytics when `AppConfig.firebaseEnabled` -> the same guard here
  /// keeps tests and unprovisioned builds off an uninitialised SDK.
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

String _$crashReporterHash() => r'3d0ab228de79ac4a7ac327cde4f9f23073815a2d';
