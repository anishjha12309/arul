import 'package:freezed_annotation/freezed_annotation.dart';

part 'referral_model.freezed.dart';
part 'referral_model.g.dart';

enum ReferralStatus {
  @JsonValue('pending')
  pending,
  @JsonValue('subscribed')
  subscribed,
  @JsonValue('rewarded')
  rewarded,
}

/// A referral record (Neon `referrals`): who referred whom and the reward state.
@freezed
abstract class ReferralModel with _$ReferralModel {
  @JsonSerializable(fieldRename: FieldRename.snake)
  const factory ReferralModel({
    required String id,
    required String referrerId,
    required String referredUserId,
    required ReferralStatus status,
    required int rewardDays,
    DateTime? createdAt,

    /// Friend's display label from the Worker (`/me/referrals`): their name, or a
    /// masked email fallback, or null. Never the raw email (privacy).
    String? referredName,
  }) = _ReferralModel;

  factory ReferralModel.fromJson(Map<String, dynamic> json) =>
      _$ReferralModelFromJson(json);
}
