import '../../../data/models/subscription_model.dart';

/// Derived entitlement state from a user's subscription row.
/// isPremium = status ∈ {trialing, active, cancelled} AND current_period_end > now().
/// `cancelled` is included so a user who cancels keeps premium until the paid
/// period ends (only renewal stops); `paused`/`expired` get no access.
class Entitlement {
  const Entitlement({required this.isPremium, this.subscription});

  /// No subscription found — free-tier access only.
  const Entitlement.none() : isPremium = false, subscription = null;

  /// Builds entitlement from a subscription row (null → free tier).
  factory Entitlement.fromSubscription(SubscriptionModel? sub) {
    if (sub == null) return const Entitlement.none();

    final isActive =
        sub.status == SubscriptionStatus.trialing ||
        sub.status == SubscriptionStatus.active ||
        // Cancelled but still inside the paid period → keep access until it ends.
        sub.status == SubscriptionStatus.cancelled;

    final notExpired =
        sub.currentPeriodEnd != null &&
        sub.currentPeriodEnd!.isAfter(DateTime.now());

    return Entitlement(isPremium: isActive && notExpired, subscription: sub);
  }

  final bool isPremium;
  final SubscriptionModel? subscription;

  @override
  String toString() =>
      'Entitlement(isPremium: $isPremium, status: ${subscription?.status})';
}
