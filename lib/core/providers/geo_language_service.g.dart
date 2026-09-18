// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'geo_language_service.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(geoLanguageService)
final geoLanguageServiceProvider = GeoLanguageServiceProvider._();

final class GeoLanguageServiceProvider
    extends
        $FunctionalProvider<
          GeoLanguageService,
          GeoLanguageService,
          GeoLanguageService
        >
    with $Provider<GeoLanguageService> {
  GeoLanguageServiceProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'geoLanguageServiceProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$geoLanguageServiceHash();

  @$internal
  @override
  $ProviderElement<GeoLanguageService> $createElement(
    $ProviderPointer pointer,
  ) => $ProviderElement(pointer);

  @override
  GeoLanguageService create(Ref ref) {
    return geoLanguageService(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(GeoLanguageService value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<GeoLanguageService>(value),
    );
  }
}

String _$geoLanguageServiceHash() =>
    r'25f3cb31a4104318b7a0f824b4ebc24362181f33';
