import '../../../core/api/api_client.dart';
import '../../../data/models/subscription_model.dart';
import '../domain/entitlement.dart';
import '../domain/subscription_repository.dart';

/// Fetches the current user's entitlement from the Worker's merged `GET /me`.
class ApiSubscriptionRepository implements SubscriptionRepository {
  const ApiSubscriptionRepository({required ApiClient apiClient})
    : _api = apiClient;

  final ApiClient _api;

  @override
  Future<Entitlement> getEntitlement(String userId) async {
    // GET /me returns `{ user, subscription, premium }` in one call. Cold
    // start already fires /me for the auth upgrade, so folding entitlement in
    // means one Neon-backed request instead of two (ApiClient coalesces the
    // in-flight GETs, so this doesn't even double the HTTP call).
    //
    // `premium` is the Worker-computed flag — the ONLY source of the premium
    // decision (see Entitlement). Strict == true so anything missing or odd
    // fails CLOSED to free; the Worker's /media/signed-url stays the real gate.
    try {
      final data = await _api.get('/me');
      final sub = data['subscription'] as Map<String, dynamic>?;
      return Entitlement(
        isPremium: data['premium'] == true,
        subscription: sub == null ? null : SubscriptionModel.fromJson(sub),
      );
    } on ApiException catch (e) {
      // 404 = the users row itself is gone (account deleted from another
      // device while this session's access token was still live). The
      // entitlement must degrade to free, not error.
      if (e.status == 404) return const Entitlement.none();
      rethrow;
    }
  }
}
