// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'referral_model.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_ReferralModel _$ReferralModelFromJson(Map<String, dynamic> json) =>
    _ReferralModel(
      id: json['id'] as String,
      referrerId: json['referrer_id'] as String,
      referredUserId: json['referred_user_id'] as String,
      status: $enumDecode(_$ReferralStatusEnumMap, json['status']),
      rewardDays: (json['reward_days'] as num).toInt(),
      createdAt: json['created_at'] == null
          ? null
          : DateTime.parse(json['created_at'] as String),
      referredName: json['referred_name'] as String?,
    );

Map<String, dynamic> _$ReferralModelToJson(_ReferralModel instance) =>
    <String, dynamic>{
      'id': instance.id,
      'referrer_id': instance.referrerId,
      'referred_user_id': instance.referredUserId,
      'status': _$ReferralStatusEnumMap[instance.status]!,
      'reward_days': instance.rewardDays,
      'created_at': instance.createdAt?.toIso8601String(),
      'referred_name': instance.referredName,
    };

const _$ReferralStatusEnumMap = {
  ReferralStatus.pending: 'pending',
  ReferralStatus.subscribed: 'subscribed',
  ReferralStatus.rewarded: 'rewarded',
};
