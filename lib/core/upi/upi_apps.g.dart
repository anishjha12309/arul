// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'upi_apps.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// Installed mandate-capable UPI apps for the paywall picker.
/// The set changes only on an install or uninstall -> keepAlive; re-querying per open buys nothing.

@ProviderFor(installedUpiApps)
final installedUpiAppsProvider = InstalledUpiAppsProvider._();

/// Installed mandate-capable UPI apps for the paywall picker.
/// The set changes only on an install or uninstall -> keepAlive; re-querying per open buys nothing.

final class InstalledUpiAppsProvider
    extends
        $FunctionalProvider<
          AsyncValue<List<UpiApp>>,
          List<UpiApp>,
          FutureOr<List<UpiApp>>
        >
    with $FutureModifier<List<UpiApp>>, $FutureProvider<List<UpiApp>> {
  /// Installed mandate-capable UPI apps for the paywall picker.
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
  $FutureProviderElement<List<UpiApp>> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<List<UpiApp>> create(Ref ref) {
    return installedUpiApps(ref);
  }
}

String _$installedUpiAppsHash() => r'bbd43ff85da000d51a168eefcf89b97a7cd90d11';
