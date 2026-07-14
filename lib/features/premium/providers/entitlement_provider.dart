import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/analytics/analytics_provider.dart';
import '../../../core/config/app_config.dart';
import '../../../data/repositories/repository_providers.dart';
import '../../auth/providers/auth_providers.dart';
import '../domain/entitlement.dart';

/// Premium entitlement — a LIVE read of the user's subscription row from the
/// Worker (`/me/subscription`), never a cached claim and never a JWT claim, so
/// a purchase, expiry or refund takes effect on the very next gated tap
/// (CLAUDE.md §5). `ref.invalidate(entitlementProvider)` after a purchase /
/// cancel re-reads it.
///
/// isPremium = status ∈ {trialing, active, cancelled} AND
/// current_period_end > now (see [Entitlement.fromSubscription]); the server
/// additionally ORs in `reward_premium_until`. Without a backend (or signed
/// out) nobody is premium — the gate fails closed, which is the correct
/// default; the Worker's `/media/signed-url` stays the authoritative gate.
final entitlementProvider = FutureProvider<bool>((ref) async {
  if (!AppConfig.hasBackend) return false;

  // Read the auth service's SYNCHRONOUS currentState, not the stream's
  // `.future`: authStateChanges is a broadcast controller that does not replay
  // its last event to new listeners, so awaiting `.future` after the single
  // emission has already passed hangs forever (which silently froze the
  // apply/share gate). `currentState` always reflects the latest emission and
  // is seeded to `unauthenticated` before the first event, so a loading moment
  // reads as not-yet-authenticated (fail-closed) rather than bouncing a paying
  // user — and the real gate is the Worker's /media/signed-url check anyway.
  // We still watch the stream so entitlement re-resolves when auth changes.
  ref.watch(authStateStreamProvider);
  final authState = ref.read(authServiceProvider).currentState;
  if (!authState.isAuthenticated) return false;

  final sub = await ref
      .watch(subscriptionRepositoryProvider)
      .getSubscription(authState.userId!);
  return Entitlement.fromSubscription(sub).isPremium;
});

/// THE client gate. Call before every gated action; it is UX only — the real
/// gate is the Worker's `/media/signed-url` live entitlement check.
///
/// It AWAITS the future rather than reading `.valueOrNull`. That is not
/// pedantry: reading a loading snapshot would bounce a paying user to the
/// paywall on a cold start, which is precisely the bug this signature exists to
/// make impossible.
Future<bool> ensurePremium(
  BuildContext context,
  WidgetRef ref, {
  required String source,
}) async {
  bool premium;
  try {
    premium = await ref.read(entitlementProvider.future);
  } catch (_) {
    // Entitlement fetch failed (network/auth). Fall through to the paywall UX;
    // the server-side gate still enforces the real check on the signed-url call.
    premium = false;
  }
  if (premium) return true;

  ref.read(analyticsServiceProvider).track('${source}_blocked_premium');

  if (context.mounted) {
    unawaited(context.push('/premium?source=$source'));
  }
  return false;
}
