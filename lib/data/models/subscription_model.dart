import 'package:freezed_annotation/freezed_annotation.dart';

part 'subscription_model.freezed.dart';
part 'subscription_model.g.dart';

enum SubscriptionStatus {
  @JsonValue('trialing')
  trialing,
  @JsonValue('active')
  active,
  @JsonValue('paused')
  paused,
  @JsonValue('cancelled')
  cancelled,
  @JsonValue('expired')
  expired,
}

/// A user's subscription row (Neon `subscriptions`). Premium = status
/// `trialing`/`active` with `currentPeriodEnd` still in the future.
@freezed
abstract class SubscriptionModel with _$SubscriptionModel {
  @JsonSerializable(fieldRename: FieldRename.snake)
  const factory SubscriptionModel({
    required String id,
    required String userId,
    required SubscriptionStatus status,
    String? plan,
    String? phonepeSubscriptionId,
    String? merchantSubscriptionId,
    DateTime? trialEnd,
    DateTime? currentPeriodEnd,
    DateTime? updatedAt,
  }) = _SubscriptionModel;

  factory SubscriptionModel.fromJson(Map<String, dynamic> json) =>
      _$SubscriptionModelFromJson(json);
}
