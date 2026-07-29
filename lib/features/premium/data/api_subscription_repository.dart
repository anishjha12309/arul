import '../../../core/api/api_client.dart';
import '../../../data/models/subscription_model.dart';
import '../domain/subscription_repository.dart';

/// Fetches the current user's subscription from the Worker's merged `GET /me`.
class ApiSubscriptionRepository implements SubscriptionRepository {
  const ApiSubscriptionRepository({required ApiClient apiClient})
    : _api = apiClient;

  final ApiClient _api;

  @override
  Future<SubscriptionModel?> getSubscription(String userId) async {
    // GET /me now returns `{ user, subscription }` in one call — the same
    // snake_case row `/me/subscription` used to return, just nested. Cold
    // start already fires /me for the auth upgrade, so folding entitlement in
    // means one Neon-backed request instead of two (ApiClient coalesces the
    // in-flight GETs, so this doesn't even double the HTTP call). The Worker
    // keeps `/me/subscription` alive for old builds — not used here anymore.
    try {
      final data = await _api.get('/me');
      final sub = data['subscription'] as Map<String, dynamic>?;
      if (sub == null) return null;
      return SubscriptionModel.fromJson(sub);
    } on ApiException catch (e) {
      // 404 = the users row itself is gone (account deleted from another
      // device while this session's access token was still live). Same
      // "no subscription" answer the old /me/subscription 404 mapped to —
      // the entitlement must degrade to free, not error.
      if (e.status == 404) return null;
      rethrow;
    }
  }
}
