// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'premium_purchase_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(PremiumPurchase)
final premiumPurchaseProvider = PremiumPurchaseProvider._();

final class PremiumPurchaseProvider
    extends $NotifierProvider<PremiumPurchase, PurchaseState> {
  PremiumPurchaseProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'premiumPurchaseProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$premiumPurchaseHash();

  @$internal
  @override
  PremiumPurchase create() => PremiumPurchase();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(PurchaseState value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<PurchaseState>(value),
    );
  }
}

String _$premiumPurchaseHash() => r'0658d6dba97b668c18213b9ab249418b3304dc8d';

abstract class _$PremiumPurchase extends $Notifier<PurchaseState> {
  PurchaseState build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<PurchaseState, PurchaseState>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<PurchaseState, PurchaseState>,
              PurchaseState,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}
