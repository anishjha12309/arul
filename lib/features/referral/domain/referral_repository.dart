import '../../../data/models/referral_model.dart';
import 'referral_summary.dart';

/// Read access to the current user's referrals.
abstract interface class ReferralRepository {
  /// Returns all referrals where the current user is the referrer.
  Future<List<ReferralModel>> getReferrals(String referrerId);

  /// The full Refer & Earn summary — own code, referrals, total days — from one `/me/referrals`.
  Future<ReferralSummary> getReferralSummary();
}
