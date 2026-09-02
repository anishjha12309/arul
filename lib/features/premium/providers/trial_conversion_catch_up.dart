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

/// Monthly price in rupees from the remote app_config (`amount` is paise); null until it loads.
/// Shared with the purchase notifier -> a late `trial_started` carries exactly an in-session `value`.
double? monthlyPriceRupees(AppConfigModel? config) {
  final monthly = config?.prices['monthly'];
  if (monthly is Map && monthly['amount'] is num) {
    return (monthly['amount'] as num) / 100;
  }
  return null;
}

/// Fires `trial_started` LATE for a trial that was granted with the app closed.
///
/// `trial_started` is the ONLY event campaigns bid on, and it fired from ONE place: the poll loop.
/// A trial granted any other way reached the Neon row and NO sink — 13–15% of real trials.
/// The server must NOT send it instead: two source types for one conversion desyncs attribution.
/// So the SAME app SDK fires it, just late — on the next `GET /me` showing an unreported trial.
/// The marker is the last reported SETUP order id ([prefsKey]), written before the invalidate.
/// So the refresh that follows an in-session fire can never re-fire it.
/// Keyed on the ORDER, not a boolean -> a second account on the same device gets its own event.
/// The ~85% that fire in-session are untouched — same instant, same path.
/// A pre-catch-up install cannot tell "fired on the old build" from "lost".
/// So its first [reconcile] records the order WITHOUT firing — never risk a double count.
/// A fresh install has no such history and fires.
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

  /// Records [orderId] as reported.
  ///
  /// `SharedPreferences` updates its cache synchronously -> a [reconcile] this tick already sees it.
  /// The disk write is fire-and-forget — a lost write re-fires ONE event, the harmless direction.
  void markReported(String orderId) {
    unawaited(_prefs.setString(prefsKey, orderId));
  }

  /// Whether [orderId]'s `trial_started` already went out from this install.
  /// BOTH emitters consult it -> the two paths can never count one order twice.
  bool isReported(String orderId) => _prefs.getString(prefsKey) == orderId;

  /// Fires the late `trial_started` when [entitlement] carries an unreported trialing row.
  /// NEVER throws — it runs inside the entitlement read, which must not fail for analytics.
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
        // Nothing owed -> initialise the marker, so a later lost trial reads as new, not old.
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
          // Separates recovered from in-session in every sink -> measurable without a second name.
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

/// App-wide [TrialConversionCatchUp].
/// `isFreshInstall` is read once — the cohort draw resolves in `main()` before the first read.
final trialConversionCatchUpProvider = Provider<TrialConversionCatchUp>((ref) {
  return TrialConversionCatchUp(
    prefs: ref.watch(sharedPreferencesProvider),
    analytics: ref.watch(analyticsServiceProvider),
    monthlyPriceRupees: () =>
        monthlyPriceRupees(ref.read(appConfigProvider).asData?.value),
    isFreshInstall: AnalyticsCohort.isFreshInstall,
  );
});
