import 'package:freezed_annotation/freezed_annotation.dart';

part 'subscription_model.freezed.dart';
part 'subscription_model.g.dart';

// An unknown status makes fromJson throw and errors the WHOLE entitlement fetch -> this enum must
// cover every value the Worker can write to subscriptions.status.
enum SubscriptionStatus {
  @JsonValue('pending')
  pending,
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

/// A user's subscription row (Neon `subscriptions`).
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

    /// The SETUP order id (`DKS_…`) — what the purchase notifier sends as `trial_started`'s
    /// `order_id`.
    ///
    /// `TrialConversionCatchUp` keys on it -> a trial granted with the app closed still fires
    /// `trial_started`, exactly once per order.
    /// Null on Workers that predate the field -> the catch-up reads that as nothing to reconcile.
    String? merchantOrderId,
    DateTime? trialEnd,
    DateTime? currentPeriodEnd,
    DateTime? updatedAt,

    /// What the mandate charges a month, in paise. A Worker that predates the field sold ₹199 only.
    @Default(19900) int pricePaise,

    /// Whether cancelling first offers the ₹99 switch — the Worker's once-per-person verdict.
    @Default(false) bool cancelOfferEligible,
  }) = _SubscriptionModel;

  factory SubscriptionModel.fromJson(Map<String, dynamic> json) =>
      _$SubscriptionModelFromJson(json);
}
