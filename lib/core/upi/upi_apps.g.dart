// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'upi_apps.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// The device's UPI-mandate probe for the paywall picker.
/// The set changes only on an install or uninstall -> keepAlive; re-querying per open buys nothing.

@ProviderFor(installedUpiApps)
final installedUpiAppsProvider = InstalledUpiAppsProvider._();

/// The device's UPI-mandate probe for the paywall picker.
/// The set changes only on an install or uninstall -> keepAlive; re-querying per open buys nothing.

final class InstalledUpiAppsProvider
    extends $FunctionalProvider<AsyncValue<UpiScan>, UpiScan, FutureOr<UpiScan>>
    with $FutureModifier<UpiScan>, $FutureProvider<UpiScan> {
  /// The device's UPI-mandate probe for the paywall picker.
  /// The set changes only on an install or uninstall -> keepAlive; re-querying per open buys nothing.
  InstalledUpiAppsProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'installedUpiAppsProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$installedUpiAppsHash();

  @$internal
  @override
  $FutureProviderElement<UpiScan> $createElement($ProviderPointer pointer) =>
      $FutureProviderElement(pointer);

  @override
  FutureOr<UpiScan> create(Ref ref) {
    return installedUpiApps(ref);
  }
}

String _$installedUpiAppsHash() => r'0e83bc05542377dd92a79c6c9255ccf2609721cc';
