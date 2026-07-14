import '../../../data/models/referral_model.dart';
import 'referral_summary.dart';

/// Read access to the current user's referrals.
abstract interface class ReferralRepository {
  /// Returns all referrals where the current user is the referrer.
  Future<List<ReferralModel>> getReferrals(String referrerId);

  /// Returns the full Refer & Earn summary (own code + referrals + total days)
  /// from a single `/me/referrals` call.
  Future<ReferralSummary> getReferralSummary();
}
