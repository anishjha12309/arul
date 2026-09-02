import 'entitlement.dart';

/// Read access to the current user's entitlement.
abstract interface class SubscriptionRepository {
  /// The server-computed entitlement — premium flag plus the subscription row, for display.
  /// [Entitlement.none] when the user has no account state.
  Future<Entitlement> getEntitlement(String userId);
}
