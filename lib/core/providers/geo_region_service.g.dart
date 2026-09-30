// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'geo_region_service.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(geoRegionService)
final geoRegionServiceProvider = GeoRegionServiceProvider._();

final class GeoRegionServiceProvider
    extends
        $FunctionalProvider<
          GeoRegionService,
          GeoRegionService,
          GeoRegionService
        >
    with $Provider<GeoRegionService> {
  GeoRegionServiceProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'geoRegionServiceProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$geoRegionServiceHash();

  @$internal
  @override
  $ProviderElement<GeoRegionService> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  GeoRegionService create(Ref ref) {
    return geoRegionService(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(GeoRegionService value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<GeoRegionService>(value),
    );
  }
}

String _$geoRegionServiceHash() => r'e0cc5bd05f54054b2be784ac9d70014cd4af9ed3';
