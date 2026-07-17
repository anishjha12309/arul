// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'premium_purchase_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// Manages the PhonePe Standard Checkout trial-start flow.
///
/// Flow:
///   1. POST /payments/initiate  → get orderId / token / merchantId / environment
///   2. PhonePePaymentSdk.init() with the returned environment + merchantId
///   3. PhonePePaymentSdk.startTransaction() with the order payload
///   4. Poll POST /payments/status until status ∈ {trialing, active}
///   5. Invalidate entitlementProvider so the UI reflects the new state

@ProviderFor(PremiumPurchase)
final premiumPurchaseProvider = PremiumPurchaseProvider._();

/// Manages the PhonePe Standard Checkout trial-start flow.
///
/// Flow:
///   1. POST /payments/initiate  → get orderId / token / merchantId / environment
///   2. PhonePePaymentSdk.init() with the returned environment + merchantId
///   3. PhonePePaymentSdk.startTransaction() with the order payload
///   4. Poll POST /payments/status until status ∈ {trialing, active}
///   5. Invalidate entitlementProvider so the UI reflects the new state
final class PremiumPurchaseProvider
    extends $NotifierProvider<PremiumPurchase, PurchaseState> {
  /// Manages the PhonePe Standard Checkout trial-start flow.
  ///
  /// Flow:
  ///   1. POST /payments/initiate  → get orderId / token / merchantId / environment
  ///   2. PhonePePaymentSdk.init() with the returned environment + merchantId
  ///   3. PhonePePaymentSdk.startTransaction() with the order payload
  ///   4. Poll POST /payments/status until status ∈ {trialing, active}
  ///   5. Invalidate entitlementProvider so the UI reflects the new state
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

String _$premiumPurchaseHash() => r'9a32bb24f1e197bcd9e49c622da06a5d91af7210';

/// Manages the PhonePe Standard Checkout trial-start flow.
///
/// Flow:
///   1. POST /payments/initiate  → get orderId / token / merchantId / environment
///   2. PhonePePaymentSdk.init() with the returned environment + merchantId
///   3. PhonePePaymentSdk.startTransaction() with the order payload
///   4. Poll POST /payments/status until status ∈ {trialing, active}
///   5. Invalidate entitlementProvider so the UI reflects the new state

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
