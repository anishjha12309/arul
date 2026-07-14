import 'package:riverpod_annotation/riverpod_annotation.dart';

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

// ─── CDN infrastructure ───────────────────────────────────────────────────────

/// Shared resolver for the always-fresh catalog version pointer. A single
/// instance is shared by the catalog client and the app-config repo so all
/// catalog reads in a load cycle stamp the same `?v=<version>` (see
/// CatalogVersion) — keeping a paginated drain consistent.
final _catalogVersion = CatalogVersion(cdnBaseUrl: AppConfig.cdnBaseUrl);

/// Force the catalog version pointer to be re-read on the next fetch. Call this
/// on an explicit refresh so a just-published version is picked up immediately
/// (otherwise the session-cached version is reused).
void invalidateCatalogVersion() => _catalogVersion.invalidate();

/// Shared client for the edge-cached catalog JSON (public CDN, no auth).
@Riverpod(keepAlive: true)
CatalogHttpClient catalogHttpClient(Ref ref) => CatalogHttpClient(
  cdnBaseUrl: AppConfig.cdnBaseUrl,
  version: _catalogVersion,
);

// ─── Per-user (Worker-backed) repositories ────────────────────────────────────

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

/// The singleton remote app configuration (support email, prices, policy URLs,
/// feature flags). Null until the catalog `app_config.json` has been baked, so
/// consumers must provide their own fallbacks.
@Riverpod(keepAlive: true)
Future<AppConfigModel?> appConfig(Ref ref) =>
    ref.watch(appConfigRepositoryProvider).getAppConfig();
