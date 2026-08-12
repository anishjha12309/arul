import 'entitlement.dart';

/// Read access to the current user's entitlement.
abstract interface class SubscriptionRepository {
  /// Returns the server-computed entitlement (premium flag + the subscription
  /// row for display). [Entitlement.none] when the user has no account state.
  Future<Entitlement> getEntitlement(String userId);
}
