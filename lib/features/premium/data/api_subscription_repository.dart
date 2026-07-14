import '../../../core/api/api_client.dart';
import '../../../data/models/subscription_model.dart';
import '../domain/subscription_repository.dart';

/// Fetches the current user's subscription from the Worker (`/me/subscription`).
class ApiSubscriptionRepository implements SubscriptionRepository {
  const ApiSubscriptionRepository({required ApiClient apiClient})
    : _api = apiClient;

  final ApiClient _api;

  @override
  Future<SubscriptionModel?> getSubscription(String userId) async {
    // GET /me/subscription (Worker, architecture.md §3.5) → snake_case row
    // matching SubscriptionModel; 404 → null.
    try {
      final data = await _api.get('/me/subscription');
      return SubscriptionModel.fromJson(data);
    } on ApiException catch (e) {
      if (e.status == 404) return null;
      rethrow;
    }
  }
}
