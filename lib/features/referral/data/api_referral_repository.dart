import '../../../core/api/api_client.dart';
import '../../../data/models/referral_model.dart';
import '../domain/referral_repository.dart';
import '../domain/referral_summary.dart';

/// Fetches the current user's referrals from the Worker (`/me/referrals`).
class ApiReferralRepository implements ReferralRepository {
  const ApiReferralRepository({required ApiClient apiClient})
    : _api = apiClient;

  final ApiClient _api;

  @override
  Future<List<ReferralModel>> getReferrals(String referrerId) async {
    // GET /me/referrals (Worker, architecture.md §3.5) → { items: [...] }; 404 → [].
    try {
      final data = await _api.get('/me/referrals');
      return _parseItems(data);
    } on ApiException catch (e) {
      if (e.status == 404) return [];
      rethrow;
    }
  }

  @override
  Future<ReferralSummary> getReferralSummary() async {
    // GET /me/referrals → { referral_code, items: [...], total_reward_days }.
    try {
      final data = await _api.get('/me/referrals');
      final items = _parseItems(data);
      final total =
          (data['total_reward_days'] as num?)?.toInt() ??
          // Fallback: derive from items if the server didn't send a total.
          items.fold<int>(0, (sum, r) => sum + r.rewardDays);
      return ReferralSummary(
        referralCode: data['referral_code'] as String?,
        referrals: items,
        totalRewardDays: total,
      );
    } on ApiException catch (e) {
      if (e.status == 404) {
        return const ReferralSummary(
          referralCode: null,
          referrals: [],
          totalRewardDays: 0,
        );
      }
      rethrow;
    }
  }

  List<ReferralModel> _parseItems(Map<String, dynamic> data) {
    final items = data['items'] as List? ?? [];
    return items
        .cast<Map<String, dynamic>>()
        .map(ReferralModel.fromJson)
        .toList();
  }
}
