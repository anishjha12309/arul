import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/analytics/analytics_events.dart';
import '../../../core/analytics/analytics_provider.dart';
import '../../../core/analytics/analytics_service.dart';
import '../../../core/analytics/journey_stamps.dart';
import '../../../core/providers/shared_preferences_provider.dart';
import '../../../data/models/app_config_model.dart';
import '../../../data/models/subscription_model.dart';
import '../../../data/repositories/repository_providers.dart';
import '../domain/entitlement.dart';

/// Monthly price in rupees from the remote app_config (`amount` is paise), else ₹199.
/// Shared with the purchase notifier -> a late `trial_started` carries exactly an in-session `value`.
/// Never null: Ads books a valueless conversion at ₹1 (docs/google-ads.md); ₹199 is the paywall's.
double monthlyPriceRupees(AppConfigModel? config) {
  final monthly = config?.prices['monthly'];
  if (monthly is Map && monthly['amount'] is num) {
    return (monthly['amount'] as num) / 100;
  }
  return 199;
}

/// Fires `trial_started` LATE for a trial that was granted with the app closed.
class TrialConversionCatchUp {
  TrialConversionCatchUp({
    required SharedPreferences prefs,
    required AnalyticsService analytics,
    required double Function() monthlyPriceRupees,
  }) : _prefs = prefs,
       _analytics = analytics,
       _monthlyPriceRupees = monthlyPriceRupees;

  final SharedPreferences _prefs;
  final AnalyticsService _analytics;
  final double Function() _monthlyPriceRupees;

  // ignore_for_file: prefer_initializing_formals — private named parameters
  // would leak the underscore into the public constructor signature.

  /// Last SETUP order id whose `trial_started` this install has emitted.
  /// `''` = open, nothing reported yet; absent = no trial of this install's making can exist yet.
  static const prefsKey = 'arul_trial_started_reported_v1';

  /// Opens the marker at the checkout tap -> this install's trial stays owed even before any `GET /me`.
  void noteCheckout() {
    if (_prefs.getString(prefsKey) == null) markReported('');
  }

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

      // Found, not owed: this install never ran its checkout (see the class doc).
      if (reported == null) {
        markReported(orderId);
        return false;
      }

      if (reported == orderId) return false;

      _analytics.track(
        ArulEvents.trialStarted,
        properties: {
          'plan': 'monthly',
          'order_id': orderId,
          'value': _monthlyPriceRupees(),
          // Separates recovered from in-session in every sink -> measurable without a second name.
          'late': true,
          ...JourneyStamps.conversionProps(),
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

final trialConversionCatchUpProvider = Provider<TrialConversionCatchUp>((ref) {
  return TrialConversionCatchUp(
    prefs: ref.watch(sharedPreferencesProvider),
    analytics: ref.watch(analyticsServiceProvider),
    monthlyPriceRupees: () =>
        monthlyPriceRupees(ref.read(appConfigProvider).asData?.value),
  );
});
