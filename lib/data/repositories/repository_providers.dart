import 'dart:async';

import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../core/connectivity/connectivity_provider.dart';

import '../../core/config/app_config.dart';
import '../../features/auth/providers/auth_providers.dart';
import '../../features/premium/data/api_subscription_repository.dart';
import '../../features/premium/domain/subscription_repository.dart';
import '../../features/referral/data/api_referral_repository.dart';
import '../../features/referral/domain/referral_repository.dart';
import '../../features/settings/data/api_app_config_repository.dart';
import '../../features/settings/domain/app_config_repository.dart';
import '../../features/upload/data/api_content_submission_repository.dart';
import '../../features/upload/domain/content_submission_repository.dart';
import '../catalog/catalog_http_client.dart';
import '../catalog/catalog_version.dart';
import '../models/app_config_model.dart';

part 'repository_providers.g.dart';

/// Shared resolver for the always-fresh catalog version pointer.
/// One instance for the catalog client and the app-config repo -> every read stamps the same `?v=`.
/// That is what keeps a paginated drain consistent.
final _catalogVersion = CatalogVersion(cdnBaseUrl: AppConfig.cdnBaseUrl);

/// Force the catalog version pointer to be re-read on the next fetch.
/// Call it on an explicit refresh -> a just-published version wins over the session-cached one.
void invalidateCatalogVersion() => _catalogVersion.invalidate();

@Riverpod(keepAlive: true)
CatalogHttpClient catalogHttpClient(Ref ref) => CatalogHttpClient(
  cdnBaseUrl: AppConfig.cdnBaseUrl,
  version: _catalogVersion,
);

@Riverpod(keepAlive: true)
SubscriptionRepository subscriptionRepository(Ref ref) =>
    ApiSubscriptionRepository(apiClient: ref.watch(apiClientProvider));

@Riverpod(keepAlive: true)
ContentSubmissionRepository contentSubmissionRepository(Ref ref) =>
    ApiContentSubmissionRepository(apiClient: ref.watch(apiClientProvider));

@Riverpod(keepAlive: true)
ReferralRepository referralRepository(Ref ref) =>
    ApiReferralRepository(apiClient: ref.watch(apiClientProvider));

@Riverpod(keepAlive: true)
AppConfigRepository appConfigRepository(Ref ref) =>
    ApiAppConfigRepository(version: _catalogVersion);

/// The singleton remote app configuration — support email, prices, policy URLs, feature flags.
/// Null until the catalog `app_config.json` is baked -> consumers must provide their own fallbacks.
///
/// A failed fetch must not stick for the process: an offline or slow cold start would otherwise
/// keep the built-in chip order, default prices and no `feature_flags` until the next cold start.
/// So a null answer refetches on the offline->online edge, and on one short ladder for a link that
/// was "online" all along but too slow for the 10 s timeout. A refetch never passes through loading
/// — readers use `asData`, and a flicker to loading would drop the prices they already show.
@Riverpod(keepAlive: true)
class AppConfigNotifier extends _$AppConfigNotifier {
  static const retryLadder = [
    Duration(seconds: 5),
    Duration(seconds: 20),
    Duration(seconds: 60),
  ];

  Timer? _retry;
  var _attempt = 0;
  var _fetching = false;

  @override
  Future<AppConfigModel?> build() async {
    ref.onDispose(() => _retry?.cancel());
    ref.listen(isOnlineProvider, (prev, next) {
      if (prev?.value == false && next.value == true) unawaited(_refetch());
    });
    final config = await ref.read(appConfigRepositoryProvider).getAppConfig();
    if (config == null) _scheduleRetry();
    return config;
  }

  void _scheduleRetry() {
    if (_attempt >= retryLadder.length) return;
    _retry?.cancel();
    _retry = Timer(retryLadder[_attempt++], () => unawaited(_refetch()));
  }

  Future<void> _refetch() async {
    if (_fetching || state.value != null) return;
    _fetching = true;
    try {
      final config = await ref.read(appConfigRepositoryProvider).getAppConfig();
      if (!ref.mounted) return;
      if (config != null) {
        _retry?.cancel();
        state = AsyncData(config);
      } else {
        _scheduleRetry();
      }
    } finally {
      _fetching = false;
    }
  }
}
