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
