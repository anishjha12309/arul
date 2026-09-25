import '../../../data/models/referral_model.dart';
import 'referral_summary.dart';

abstract interface class ReferralRepository {
  Future<List<ReferralModel>> getReferrals(String referrerId);

  Future<ReferralSummary> getReferralSummary();
}
