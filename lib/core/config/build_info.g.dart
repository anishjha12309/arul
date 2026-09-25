// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'build_info.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// The device tier as a provider, for widgets and providers that want to watch it.
/// Same single probe behind it — a widget and `main()` can never read different tiers.

@ProviderFor(deviceTier)
final deviceTierProvider = DeviceTierProvider._();

/// The device tier as a provider, for widgets and providers that want to watch it.
/// Same single probe behind it — a widget and `main()` can never read different tiers.

final class DeviceTierProvider
    extends
        $FunctionalProvider<
          AsyncValue<DeviceTier>,
          DeviceTier,
          FutureOr<DeviceTier>
        >
    with $FutureModifier<DeviceTier>, $FutureProvider<DeviceTier> {
  /// The device tier as a provider, for widgets and providers that want to watch it.
  /// Same single probe behind it — a widget and `main()` can never read different tiers.
  DeviceTierProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'deviceTierProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$deviceTierHash();

  @$internal
  @override
  $FutureProviderElement<DeviceTier> $createElement($ProviderPointer pointer) =>
      $FutureProviderElement(pointer);

  @override
  FutureOr<DeviceTier> create(Ref ref) {
    return deviceTier(ref);
  }
}

String _$deviceTierHash() => r'6f6a06d279a826968fe0d0807278d253fb02f57a';
