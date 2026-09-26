// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app_update_controller.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// Watched at the app root -> the update check never depends on a screen being opened.

@ProviderFor(appUpdateBootstrap)
final appUpdateBootstrapProvider = AppUpdateBootstrapProvider._();

/// Watched at the app root -> the update check never depends on a screen being opened.

final class AppUpdateBootstrapProvider
    extends $FunctionalProvider<void, void, void>
    with $Provider<void> {
  /// Watched at the app root -> the update check never depends on a screen being opened.
  AppUpdateBootstrapProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'appUpdateBootstrapProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$appUpdateBootstrapHash();

  @$internal
  @override
  $ProviderElement<void> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  void create(Ref ref) {
    return appUpdateBootstrap(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(void value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<void>(value),
    );
  }
}

String _$appUpdateBootstrapHash() =>
    r'8c3af0597be724114c051e768cba984e063f79da';
