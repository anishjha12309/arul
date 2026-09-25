// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'repository_providers.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(catalogHttpClient)
final catalogHttpClientProvider = CatalogHttpClientProvider._();

final class CatalogHttpClientProvider
    extends
        $FunctionalProvider<
          CatalogHttpClient,
          CatalogHttpClient,
          CatalogHttpClient
        >
    with $Provider<CatalogHttpClient> {
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

/// The singleton remote app configuration — support email, prices, policy URLs, feature flags.
/// Null until the catalog `app_config.json` is baked -> consumers must provide their own fallbacks.
///
/// A failed fetch must not stick for the process: an offline or slow cold start would otherwise
/// keep the built-in chip order, default prices and no `feature_flags` until the next cold start.
/// So a null answer refetches on the offline->online edge, and on one short ladder for a link that
/// was "online" all along but too slow for the 10 s timeout. A refetch never passes through loading
/// — readers use `asData`, and a flicker to loading would drop the prices they already show.

@ProviderFor(AppConfigNotifier)
final appConfigProvider = AppConfigNotifierProvider._();

/// The singleton remote app configuration — support email, prices, policy URLs, feature flags.
/// Null until the catalog `app_config.json` is baked -> consumers must provide their own fallbacks.
///
/// A failed fetch must not stick for the process: an offline or slow cold start would otherwise
/// keep the built-in chip order, default prices and no `feature_flags` until the next cold start.
/// So a null answer refetches on the offline->online edge, and on one short ladder for a link that
/// was "online" all along but too slow for the 10 s timeout. A refetch never passes through loading
/// — readers use `asData`, and a flicker to loading would drop the prices they already show.
final class AppConfigNotifierProvider
    extends $AsyncNotifierProvider<AppConfigNotifier, AppConfigModel?> {
  /// The singleton remote app configuration — support email, prices, policy URLs, feature flags.
  /// Null until the catalog `app_config.json` is baked -> consumers must provide their own fallbacks.
  ///
  /// A failed fetch must not stick for the process: an offline or slow cold start would otherwise
  /// keep the built-in chip order, default prices and no `feature_flags` until the next cold start.
  /// So a null answer refetches on the offline->online edge, and on one short ladder for a link that
  /// was "online" all along but too slow for the 10 s timeout. A refetch never passes through loading
  /// — readers use `asData`, and a flicker to loading would drop the prices they already show.
  AppConfigNotifierProvider._()
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
  String debugGetCreateSourceHash() => _$appConfigNotifierHash();

  @$internal
  @override
  AppConfigNotifier create() => AppConfigNotifier();
}

String _$appConfigNotifierHash() => r'9fce4c7e3513575b2f5aad4cd808303a36cdf095';

/// The singleton remote app configuration — support email, prices, policy URLs, feature flags.
/// Null until the catalog `app_config.json` is baked -> consumers must provide their own fallbacks.
///
/// A failed fetch must not stick for the process: an offline or slow cold start would otherwise
/// keep the built-in chip order, default prices and no `feature_flags` until the next cold start.
/// So a null answer refetches on the offline->online edge, and on one short ladder for a link that
/// was "online" all along but too slow for the 10 s timeout. A refetch never passes through loading
/// — readers use `asData`, and a flicker to loading would drop the prices they already show.

abstract class _$AppConfigNotifier extends $AsyncNotifier<AppConfigModel?> {
  FutureOr<AppConfigModel?> build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<AsyncValue<AppConfigModel?>, AppConfigModel?>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<AsyncValue<AppConfigModel?>, AppConfigModel?>,
              AsyncValue<AppConfigModel?>,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}
