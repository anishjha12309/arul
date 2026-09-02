import '../../../data/models/subscription_model.dart';

/// The user's premium entitlement, as the SERVER computed it.
///
/// [isPremium] is the Worker's `premium` on `GET /me`, NEVER derived client-side.
/// The rule lives in exactly ONE place — workers/src/lib/entitlement.ts (CLAUDE.md §5).
/// The client copy that used to live here drifted: it knew nothing of `reward_premium_until`.
/// A reward-only referrer was then paywalled by the gate the Worker would have signed for.
/// So never re-derive premium from [subscription] — it is carried only to display status and dates.
class Entitlement {
  const Entitlement({required this.isPremium, this.subscription});

  /// No account / no backend / row gone — free-tier access only.
  const Entitlement.none() : isPremium = false, subscription = null;

  final bool isPremium;
  final SubscriptionModel? subscription;

  @override
  String toString() =>
      'Entitlement(isPremium: $isPremium, status: ${subscription?.status})';
}
