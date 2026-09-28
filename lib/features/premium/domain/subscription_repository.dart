import 'entitlement.dart';

abstract interface class SubscriptionRepository {
  /// The server-computed entitlement — premium flag plus the subscription row, for display.
  /// [Entitlement.none] when the user has no account state.
  Future<Entitlement> getEntitlement(String userId);

  /// Records a paywall view in Neon (`paywall_views`), which PostHog reads through its warehouse ->
  /// the people who look and never tap become visible without a PostHog event. Never throws.
  Future<void> notePaywallView(String source, Map<String, Object> context);
}
