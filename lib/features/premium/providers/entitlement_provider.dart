import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/config/app_config.dart';

/// Premium entitlement.
///
/// Phase 4 replaces the body with a LIVE read of `GET /me` from the Worker —
/// never a cached claim, and never a JWT claim, so a purchase, expiry or refund
/// takes effect on the very next gated tap (CLAUDE.md §5). Until the Worker
/// exists nobody is premium, which is the correct default: the gate fails closed.
final entitlementProvider = FutureProvider<bool>((ref) async {
  if (!AppConfig.hasBackend) return false;
  return false;
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
  final premium = await ref.read(entitlementProvider.future);
  if (premium) return true;

  // TODO(phase-4): track '${source}_blocked_premium' via AnalyticsService.
  if (context.mounted) {
    unawaited(context.push('/premium?source=$source'));
  }
  return false;
}
