import '../../../data/models/subscription_model.dart';

/// The user's premium entitlement, as the SERVER computed it.
/// [isPremium] is the Worker's `premium` on `GET /me`, NEVER derived client-side.
class Entitlement {
  const Entitlement({required this.isPremium, this.subscription});

  const Entitlement.none() : isPremium = false, subscription = null;

  final bool isPremium;
  final SubscriptionModel? subscription;

  @override
  String toString() =>
      'Entitlement(isPremium: $isPremium, status: ${subscription?.status})';
}

/// The plan a row is shown as: a `pending` setup claim over a live period reads as the plan it left.
extension ShownPlan on SubscriptionModel {
  SubscriptionStatus shownStatus(DateTime now) {
    final end = currentPeriodEnd;
    if (status != SubscriptionStatus.pending ||
        end == null ||
        !end.isAfter(now)) {
      return status;
    }
    // Nothing paid for changes until the claim settles: a switch is off a live plan, anything else
    // (a ₹199 resubscribe or a ₹99 winback) is from `cancelled`.
    if (!offerSwitch) return SubscriptionStatus.cancelled;
    // The switch moves trial_end with the period, so a trial still reads unconverted (releaseClaim's CASE).
    final trial = trialEnd;
    return trial != null && !end.isAfter(trial)
        ? SubscriptionStatus.trialing
        : SubscriptionStatus.active;
  }
}
