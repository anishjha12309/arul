import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/analytics/analytics_provider.dart';
import '../../../core/config/app_config.dart';
import '../../../data/repositories/repository_providers.dart';
import '../../auth/providers/auth_providers.dart';
import '../domain/entitlement.dart';
import 'trial_conversion_catch_up.dart';
import 'trial_nudge_provider.dart';

/// Premium entitlement — a LIVE read from the Worker (`GET /me`), never a cached or JWT claim.
///
/// So a purchase, expiry or refund takes effect on the very next gated tap (CLAUDE.md §5).
/// `ref.invalidate(entitlementDetailProvider)` after a purchase or cancel re-reads it.
/// `isPremium` is the SERVER's flag from workers/src/lib/entitlement.ts — never re-derived here.
/// No backend, or signed out -> nobody is premium; the gate fails CLOSED, the correct default.
/// The Worker's `/media/signed-url` stays the authoritative gate either way.
/// This carries the FULL entitlement — the flag AND the row the Manage screen displays.
/// [entitlementProvider] narrows it to the bool the gate wants -> one read, two consumers.
final entitlementDetailProvider = FutureProvider<Entitlement>((ref) async {
  if (!AppConfig.hasBackend) return const Entitlement.none();

  // authStateChanges is a broadcast controller that does not replay its last event.
  // Awaiting `.future` after the single emission passed hangs forever — it froze the apply gate.
  // So read the SYNCHRONOUS `currentState`, which always reflects the latest emission.
  // It is seeded `unauthenticated` -> a loading moment fails CLOSED rather than bouncing a payer.
  // The stream is still watched, so entitlement re-resolves when auth changes.
  ref.watch(authStateStreamProvider);
  final authState = ref.read(authServiceProvider).currentState;
  if (!authState.isAuthenticated) return const Entitlement.none();

  final entitlement = await ref
      .watch(subscriptionRepositoryProvider)
      .getEntitlement(authState.userId!);

  // Every entitlement read is a chance to report a trial granted app-closed.
  // Idempotent per order -> running it on every read costs nothing.
  // Guarded, so analytics can never fail the entitlement.
  try {
    ref.read(trialConversionCatchUpProvider).reconcile(entitlement);
  } catch (e) {
    debugPrint('[entitlement] trial catch-up skipped: $e');
  }

  retireUnfinishedTrial(ref, entitlement);

  return entitlement;
});

/// A premium read retires the unfinished-trial marker, HERE and not only in the feed row.
///
/// The marker is written when the UPI app takes over, so an approval the app never saw (killed
/// behind PhonePe, confirmation unreachable) leaves it live with a reminder armed — and someone
/// who comes back through a ringtone link or sits on Settings never builds that row. Every late
/// grant passes through the entitlement read; none of them should be told "you didn't finish".
/// Guarded twice over, sync and async: a marker must never fail the entitlement.
@visibleForTesting
void retireUnfinishedTrial(Ref ref, Entitlement entitlement) {
  if (!entitlement.isPremium) return;
  try {
    final nudge = ref.read(trialNudgeProvider.notifier);
    // A microtask, as the feed row does: resolve() writes another provider's state, which
    // Riverpod forbids from inside a provider that is still building.
    unawaited(
      Future.microtask(nudge.resolve).catchError((Object e) {
        debugPrint('[entitlement] unfinished-trial marker not cleared: $e');
      }),
    );
  } catch (e) {
    debugPrint('[entitlement] unfinished-trial marker not cleared: $e');
  }
}

/// The gate's view of [entitlementDetailProvider]: just "may this user act?".
/// Invalidating [entitlementDetailProvider] cascades here automatically.
final entitlementProvider = FutureProvider<bool>((ref) async {
  final entitlement = await ref.watch(entitlementDetailProvider.future);
  return entitlement.isPremium;
});

/// THE client gate. Call before every gated action — UX only; `/media/signed-url` is the real gate.
///
/// Reading a loading snapshot bounces a paying user to the paywall on a cold start.
/// So it AWAITS the future and never reads `.valueOrNull` — the signature exists to force that.
Future<bool> ensurePremium(
  BuildContext context,
  WidgetRef ref, {
  required String source,
  Map<String, Object?>? properties,
}) async {
  bool premium;
  try {
    premium = await ref.read(entitlementProvider.future);
  } catch (_) {
    // Fetch failed -> fall through to the paywall UX; signed-url still enforces the real check.
    premium = false;
  }
  if (premium) return true;

  // `properties` attributes the block (the wallpaper id) -> the funnel says WHICH content converts.
  ref
      .read(analyticsServiceProvider)
      .track('${source}_blocked_premium', properties: properties);

  if (context.mounted) {
    unawaited(context.push('/premium?source=$source'));
  }
  return false;
}
