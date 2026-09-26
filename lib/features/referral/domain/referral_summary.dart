import '../../../data/models/referral_model.dart';

class ReferralSummary {
  const ReferralSummary({
    required this.referralCode,
    required this.referrals,
    required this.totalRewardDays,
  });

  final String? referralCode;

  final List<ReferralModel> referrals;

  /// Sum of reward_days across all referrals (30 per subscribed friend).
  final int totalRewardDays;

  bool get hasReferrals => referrals.isNotEmpty;
}
