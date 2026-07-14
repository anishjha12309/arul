// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'repository_providers.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// Shared client for the edge-cached catalog JSON (public CDN, no auth).

@ProviderFor(catalogHttpClient)
final catalogHttpClientProvider = CatalogHttpClientProvider._();

/// Shared client for the edge-cached catalog JSON (public CDN, no auth).

final class CatalogHttpClientProvider
    extends
        $FunctionalProvider<
          CatalogHttpClient,
          CatalogHttpClient,
          CatalogHttpClient
        >
    with $Provider<CatalogHttpClient> {
  /// Shared client for the edge-cached catalog JSON (public CDN, no auth).
  CatalogHttpClientProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'catalogHttpClientProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$catalogHttpClientHash();

  @$internal
  @override
  $ProviderElement<CatalogHttpClient> $createElement(
    $ProviderPointer pointer,
  ) => $ProviderElement(pointer);

  @override
  CatalogHttpClient create(Ref ref) {
    return catalogHttpClient(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(CatalogHttpClient value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<CatalogHttpClient>(value),
    );
  }
}

String _$catalogHttpClientHash() => r'aa90f9b3bfc3f223e11129537a1e9f359854e718';

@ProviderFor(subscriptionRepository)
final subscriptionRepositoryProvider = SubscriptionRepositoryProvider._();

final class SubscriptionRepositoryProvider
    extends
        $FunctionalProvider<
          SubscriptionRepository,
          SubscriptionRepository,
          SubscriptionRepository
        >
    with $Provider<SubscriptionRepository> {
  SubscriptionRepositoryProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'subscriptionRepositoryProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$subscriptionRepositoryHash();

  @$internal
  @override
  $ProviderElement<SubscriptionRepository> $createElement(
    $ProviderPointer pointer,
  ) => $ProviderElement(pointer);

  @override
  SubscriptionRepository create(Ref ref) {
    return subscriptionRepository(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(SubscriptionRepository value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<SubscriptionRepository>(value),
    );
  }
}

String _$subscriptionRepositoryHash() =>
    r'2da060584397552cabba8b51a55a9455397a6b83';

@ProviderFor(contentSubmissionRepository)
final contentSubmissionRepositoryProvider =
    ContentSubmissionRepositoryProvider._();

final class ContentSubmissionRepositoryProvider
    extends
        $FunctionalProvider<
          ContentSubmissionRepository,
          ContentSubmissionRepository,
          ContentSubmissionRepository
        >
    with $Provider<ContentSubmissionRepository> {
  ContentSubmissionRepositoryProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'contentSubmissionRepositoryProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$contentSubmissionRepositoryHash();

  @$internal
  @override
  $ProviderElement<ContentSubmissionRepository> $createElement(
    $ProviderPointer pointer,
  ) => $ProviderElement(pointer);

  @override
  ContentSubmissionRepository create(Ref ref) {
    return contentSubmissionRepository(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(ContentSubmissionRepository value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<ContentSubmissionRepository>(value),
    );
  }
}

String _$contentSubmissionRepositoryHash() =>
    r'aac01efd8a9d735c77ff75c9fca8e45222000b4e';

@ProviderFor(referralRepository)
final referralRepositoryProvider = ReferralRepositoryProvider._();

final class ReferralRepositoryProvider
    extends
        $FunctionalProvider<
          ReferralRepository,
          ReferralRepository,
          ReferralRepository
        >
    with $Provider<ReferralRepository> {
  ReferralRepositoryProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'referralRepositoryProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$referralRepositoryHash();

  @$internal
  @override
  $ProviderElement<ReferralRepository> $createElement(
    $ProviderPointer pointer,
  ) => $ProviderElement(pointer);

  @override
  ReferralRepository create(Ref ref) {
    return referralRepository(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(ReferralRepository value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<ReferralRepository>(value),
    );
  }
}

String _$referralRepositoryHash() =>
    r'aa7e77c25655f3089f5731c13f55c44be234cbbe';

@ProviderFor(appConfigRepository)
final appConfigRepositoryProvider = AppConfigRepositoryProvider._();

final class AppConfigRepositoryProvider
    extends
        $FunctionalProvider<
          AppConfigRepository,
          AppConfigRepository,
          AppConfigRepository
        >
    with $Provider<AppConfigRepository> {
  AppConfigRepositoryProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'appConfigRepositoryProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$appConfigRepositoryHash();

  @$internal
  @override
  $ProviderElement<AppConfigRepository> $createElement(
    $ProviderPointer pointer,
  ) => $ProviderElement(pointer);

  @override
  AppConfigRepository create(Ref ref) {
    return appConfigRepository(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(AppConfigRepository value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<AppConfigRepository>(value),
    );
  }
}

String _$appConfigRepositoryHash() =>
    r'92968e48a8811781d12a7a3023559f27861b555d';

/// The singleton remote app configuration (support email, prices, policy URLs,
/// feature flags). Null until the catalog `app_config.json` has been baked, so
/// consumers must provide their own fallbacks.

@ProviderFor(appConfig)
final appConfigProvider = AppConfigProvider._();

/// The singleton remote app configuration (support email, prices, policy URLs,
/// feature flags). Null until the catalog `app_config.json` has been baked, so
/// consumers must provide their own fallbacks.

final class AppConfigProvider
    extends
        $FunctionalProvider<
          AsyncValue<AppConfigModel?>,
          AppConfigModel?,
          FutureOr<AppConfigModel?>
        >
    with $FutureModifier<AppConfigModel?>, $FutureProvider<AppConfigModel?> {
  /// The singleton remote app configuration (support email, prices, policy URLs,
  /// feature flags). Null until the catalog `app_config.json` has been baked, so
  /// consumers must provide their own fallbacks.
  AppConfigProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'appConfigProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$appConfigHash();

  @$internal
  @override
  $FutureProviderElement<AppConfigModel?> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<AppConfigModel?> create(Ref ref) {
    return appConfig(ref);
  }
}

String _$appConfigHash() => r'e62972c1fad4392f942f6253a51ecb0b15b7f95a';
