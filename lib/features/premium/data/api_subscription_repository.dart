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
    // Cold start already fires /me for the auth upgrade -> folding entitlement into its
    // `{user, subscription, premium}` adds no Neon request (ApiClient coalesces in-flight GETs).
    // `premium` is the Worker-computed flag and the ONLY source of the decision (see Entitlement) ->
    // strict `== true` fails CLOSED to free -> the Worker's /media/signed-url stays the real gate.
    try {
      final data = await _api.get('/me');
      final sub = data['subscription'] as Map<String, dynamic>?;
      return Entitlement(
        isPremium: data['premium'] == true,
        subscription: sub == null ? null : SubscriptionModel.fromJson(sub),
      );
    } on ApiException catch (e) {
      // 404 = the users row is gone (deleted on another device while this access token was live) ->
      // degrade to free, never error.
      if (e.status == 404) return const Entitlement.none();
      rethrow;
    }
  }
}
