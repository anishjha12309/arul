// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'install_referrer_service.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(installReferrerService)
final installReferrerServiceProvider = InstallReferrerServiceProvider._();

final class InstallReferrerServiceProvider
    extends
        $FunctionalProvider<
          InstallReferrerService,
          InstallReferrerService,
          InstallReferrerService
        >
    with $Provider<InstallReferrerService> {
  InstallReferrerServiceProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'installReferrerServiceProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$installReferrerServiceHash();

  @$internal
  @override
  $ProviderElement<InstallReferrerService> $createElement(
    $ProviderPointer pointer,
  ) => $ProviderElement(pointer);

  @override
  InstallReferrerService create(Ref ref) {
    return installReferrerService(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(InstallReferrerService value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<InstallReferrerService>(value),
    );
  }
}

String _$installReferrerServiceHash() =>
    r'5a728569571a728f157aa4bf09faad970f6e03dc';
