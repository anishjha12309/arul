import '../../../data/models/subscription_model.dart';

/// Read access to the current user's subscription row.
abstract interface class SubscriptionRepository {
  /// Returns the current user's subscription, or null if none exists.
  Future<SubscriptionModel?> getSubscription(String userId);
}
