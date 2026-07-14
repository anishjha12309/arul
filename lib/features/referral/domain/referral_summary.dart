import '../../../data/models/referral_model.dart';

/// Everything the Refer & Earn screen needs, from a single `/me/referrals` call:
/// the caller's own code (for the share link), their referrals, and the total
/// free-premium days earned.
class ReferralSummary {
  const ReferralSummary({
    required this.referralCode,
    required this.referrals,
    required this.totalRewardDays,
  });

  /// The current user's referral code (null only if the server omitted it).
  final String? referralCode;

  /// Referrals where the current user is the referrer, newest first.
  final List<ReferralModel> referrals;

  /// Sum of reward_days across all referrals (30 per subscribed friend).
  final int totalRewardDays;

  bool get hasReferrals => referrals.isNotEmpty;
}
