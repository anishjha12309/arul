// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app_config_model.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_AppConfigModel _$AppConfigModelFromJson(Map<String, dynamic> json) =>
    _AppConfigModel(
      prices: json['prices'] as Map<String, dynamic>,
      supportEmail: json['support_email'] as String?,
      policyUrls: json['policy_urls'] as Map<String, dynamic>,
      featureFlags: json['feature_flags'] as Map<String, dynamic>,
      minSupportedVersion: json['min_supported_version'] as String?,
    );

Map<String, dynamic> _$AppConfigModelToJson(_AppConfigModel instance) =>
    <String, dynamic>{
      'prices': instance.prices,
      'support_email': instance.supportEmail,
      'policy_urls': instance.policyUrls,
      'feature_flags': instance.featureFlags,
      'min_supported_version': instance.minSupportedVersion,
    };
