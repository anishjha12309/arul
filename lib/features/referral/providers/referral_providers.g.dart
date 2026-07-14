// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'referral_providers.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// Play Install Referrer capture + pending-code handoff to sign-in.

@ProviderFor(installReferrerService)
final installReferrerServiceProvider = InstallReferrerServiceProvider._();

/// Play Install Referrer capture + pending-code handoff to sign-in.

final class InstallReferrerServiceProvider
    extends
        $FunctionalProvider<
          InstallReferrerService,
          InstallReferrerService,
          InstallReferrerService
        >
    with $Provider<InstallReferrerService> {
  /// Play Install Referrer capture + pending-code handoff to sign-in.
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

/// The Refer & Earn screen's data: own code + referrals + total days earned.
/// `ref.invalidate(referralSummaryProvider)` re-fetches (pull-to-refresh / the
/// app-bar refresh button).

@ProviderFor(referralSummary)
final referralSummaryProvider = ReferralSummaryProvider._();

/// The Refer & Earn screen's data: own code + referrals + total days earned.
/// `ref.invalidate(referralSummaryProvider)` re-fetches (pull-to-refresh / the
/// app-bar refresh button).

final class ReferralSummaryProvider
    extends
        $FunctionalProvider<
          AsyncValue<ReferralSummary>,
          ReferralSummary,
          FutureOr<ReferralSummary>
        >
    with $FutureModifier<ReferralSummary>, $FutureProvider<ReferralSummary> {
  /// The Refer & Earn screen's data: own code + referrals + total days earned.
  /// `ref.invalidate(referralSummaryProvider)` re-fetches (pull-to-refresh / the
  /// app-bar refresh button).
  ReferralSummaryProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'referralSummaryProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$referralSummaryHash();

  @$internal
  @override
  $FutureProviderElement<ReferralSummary> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<ReferralSummary> create(Ref ref) {
    return referralSummary(ref);
  }
}

String _$referralSummaryHash() => r'c93d4bcaa64ca1829fd495efb5a3d9afb002ba0d';
