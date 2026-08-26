import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/analytics/analytics_cohort.dart';
import '../../../core/analytics/analytics_events.dart';
import '../../../core/analytics/analytics_provider.dart';
import '../../../core/analytics/analytics_service.dart';
import '../../../core/providers/shared_preferences_provider.dart';
import '../../../data/models/app_config_model.dart';
import '../../../data/models/subscription_model.dart';
import '../../../data/repositories/repository_providers.dart';
import '../domain/entitlement.dart';

/// Monthly price in rupees from the remote app_config (`prices.monthly.amount`
/// is paise), or null when the config hasn't loaded. Shared by the purchase
/// notifier and [TrialConversionCatchUp] so a late `trial_started` carries
/// exactly the `value` an in-session one would.
double? monthlyPriceRupees(AppConfigModel? config) {
  final monthly = config?.prices['monthly'];
  if (monthly is Map && monthly['amount'] is num) {
    return (monthly['amount'] as num) / 100;
  }
  return null;
}

/// Fires `trial_started` LATE for a trial that was granted with the app closed.
///
/// WHY: `trial_started` is the ONLY event campaigns bid on, and it used to fire
/// from exactly one place — the purchase notifier's `/payments/status` polls on
/// the /premium screen. A trial granted any other way (the setup webhook
/// resurrecting an abandon-raced claim, Android killing Arul behind the UPI
/// app, the poll budget running out before PhonePe settled) reached the Neon
/// row and never reached ANY sink. Measured 2026-08-26 against Neon: 13–15% of
/// real trials had no `trial_started` in PostHog (100% cohort), i.e. the same
/// share was missing from GA4/Google Ads and Meta. The server must NOT send it
/// instead — one conversion fed by two source types (app SDK + server) is what
/// desynchronised attribution and got the server-side `purchase`/`Subscribe`
/// reporters deleted the same day. So the SAME app SDK fires it, just late: on
/// the next `GET /me` that shows a `trialing` row whose `merchant_order_id`
/// this install has not reported.
///
/// The marker is the last reported SETUP order id (`prefsKey`), written by the
/// purchase notifier BEFORE it invalidates the entitlement (so the refresh that
/// follows an in-session fire can never re-fire it) and by [reconcile] after a
/// late fire. Keyed on the order, not a boolean, so a second account on the
/// same device still gets its own event. The ~85% that fire in-session are
/// untouched — same instant, same path as before.
///
/// Grandfathering: the first [reconcile] on an install that predates this
/// class (marker never written, install not fresh) cannot tell "fired on the
/// old build" from "lost", so it records the current order WITHOUT firing —
/// one day's cohort of updaters forgoes recovery rather than risk a double
/// count on the event that makes the money. A fresh install has no such
/// history and fires.
class TrialConversionCatchUp {
  TrialConversionCatchUp({
    required SharedPreferences prefs,
    required AnalyticsService analytics,
    required double? Function() monthlyPriceRupees,
    required bool isFreshInstall,
  }) : _prefs = prefs,
       _analytics = analytics,
       _monthlyPriceRupees = monthlyPriceRupees,
       _isFreshInstall = isFreshInstall;

  final SharedPreferences _prefs;
  final AnalyticsService _analytics;
  final double? Function() _monthlyPriceRupees;
  final bool _isFreshInstall;

  // ignore_for_file: prefer_initializing_formals — private named parameters
  // would leak the underscore into the public constructor signature.

  /// Last SETUP order id whose `trial_started` this install has emitted.
  /// `''` = initialised, nothing reported yet; absent = pre-catch-up install.
  static const prefsKey = 'arul_trial_started_reported_v1';

  /// Records [orderId] as reported. `SharedPreferences` updates its in-memory
  /// cache synchronously, so a [reconcile] later in the same tick already sees
  /// it — the disk write is fire-and-forget (a lost write re-fires ONE event
  /// on the next launch, the harmless direction).
  void markReported(String orderId) {
    unawaited(_prefs.setString(prefsKey, orderId));
  }

  /// Whether [orderId]'s `trial_started` already went out from this install.
  /// Both emitters consult it — the purchase notifier before an in-session
  /// (or paywall-outliving) fire, [reconcile] before a late one — so the two
  /// paths can never count one order twice.
  bool isReported(String orderId) => _prefs.getString(prefsKey) == orderId;

  /// Fires the late `trial_started` when [entitlement] carries a trialing row
  /// this install has not reported. Returns true when it fired. Never throws:
  /// it runs inside the entitlement read, which must not fail for analytics.
  bool reconcile(Entitlement entitlement) {
    try {
      final reported = _prefs.getString(prefsKey);
      final sub = entitlement.subscription;
      final orderId = sub?.merchantOrderId;
      final trialing =
          sub != null &&
          sub.status == SubscriptionStatus.trialing &&
          orderId != null &&
          orderId.isNotEmpty;

      if (!trialing) {
        // Nothing owed. Initialise the marker so a trial that starts (and is
        // lost) later on this install is recognised as new, not grandfathered.
        if (reported == null) markReported('');
        return false;
      }

      if (reported == null && !_isFreshInstall) {
        markReported(orderId);
        return false;
      }

      if (reported == orderId) return false;

      _analytics.track(
        ArulEvents.trialStarted,
        properties: {
          'plan': 'monthly',
          'order_id': orderId,
          'value': ?_monthlyPriceRupees(),
          // Separates recovered events from in-session ones in every sink, so
          // the recovered share stays measurable without a second event name.
          'late': true,
        },
      );
      markReported(orderId);
      return true;
    } catch (e) {
      debugPrint('[TrialConversionCatchUp] reconcile failed: $e');
      return false;
    }
  }
}

/// App-wide [TrialConversionCatchUp]. `isFreshInstall` is read once here: the
/// cohort draw is resolved in `main()` before the first entitlement read.
final trialConversionCatchUpProvider = Provider<TrialConversionCatchUp>((ref) {
  return TrialConversionCatchUp(
    prefs: ref.watch(sharedPreferencesProvider),
    analytics: ref.watch(analyticsServiceProvider),
    monthlyPriceRupees: () =>
        monthlyPriceRupees(ref.read(appConfigProvider).asData?.value),
    isFreshInstall: AnalyticsCohort.isFreshInstall,
  );
});
