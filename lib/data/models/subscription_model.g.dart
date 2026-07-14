// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'subscription_model.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_SubscriptionModel _$SubscriptionModelFromJson(Map<String, dynamic> json) =>
    _SubscriptionModel(
      id: json['id'] as String,
      userId: json['user_id'] as String,
      status: $enumDecode(_$SubscriptionStatusEnumMap, json['status']),
      plan: json['plan'] as String?,
      phonepeSubscriptionId: json['phonepe_subscription_id'] as String?,
      merchantSubscriptionId: json['merchant_subscription_id'] as String?,
      trialEnd: json['trial_end'] == null
          ? null
          : DateTime.parse(json['trial_end'] as String),
      currentPeriodEnd: json['current_period_end'] == null
          ? null
          : DateTime.parse(json['current_period_end'] as String),
      updatedAt: json['updated_at'] == null
          ? null
          : DateTime.parse(json['updated_at'] as String),
    );

Map<String, dynamic> _$SubscriptionModelToJson(_SubscriptionModel instance) =>
    <String, dynamic>{
      'id': instance.id,
      'user_id': instance.userId,
      'status': _$SubscriptionStatusEnumMap[instance.status]!,
      'plan': instance.plan,
      'phonepe_subscription_id': instance.phonepeSubscriptionId,
      'merchant_subscription_id': instance.merchantSubscriptionId,
      'trial_end': instance.trialEnd?.toIso8601String(),
      'current_period_end': instance.currentPeriodEnd?.toIso8601String(),
      'updated_at': instance.updatedAt?.toIso8601String(),
    };

const _$SubscriptionStatusEnumMap = {
  SubscriptionStatus.trialing: 'trialing',
  SubscriptionStatus.active: 'active',
  SubscriptionStatus.paused: 'paused',
  SubscriptionStatus.cancelled: 'cancelled',
  SubscriptionStatus.expired: 'expired',
};
