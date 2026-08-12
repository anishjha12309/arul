import '../../../data/models/subscription_model.dart';

/// The user's premium entitlement, as the SERVER computed it.
///
/// [isPremium] is the Worker's answer (`premium` on `GET /me`), never derived
/// client-side. The rule lives in exactly ONE place —
/// workers/src/lib/entitlement.ts (subscription statuses + the debit-grace
/// window + the referral reward pool) — because the client-side copy that used
/// to live here drifted: it knew nothing about `reward_premium_until`, so a
/// referrer holding only earned reward days was bounced to the paywall by the
/// gate while the Worker's `/media/signed-url` would happily have signed for
/// them. Do not re-derive premium from [subscription]; it is carried only so
/// the premium screen can display status and dates.
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
