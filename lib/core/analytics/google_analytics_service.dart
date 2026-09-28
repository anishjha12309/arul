import 'dart:async';

import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter/foundation.dart';

import 'analytics_events.dart';
import 'analytics_service.dart';

/// [AnalyticsService] backed by Firebase Analytics (Google Analytics 4).
/// **NO `purchase` EVENT IS EMITTED ANYWHERE**, client or server (owner's call).
/// The SDK needs snake_case names ≤40 chars and String/num values -> [parametersFor] coerces, never rejects.
class GoogleAnalyticsService implements AnalyticsService {
  GoogleAnalyticsService([FirebaseAnalytics? analytics])
    : _analytics = analytics ?? FirebaseAnalytics.instance;

  final FirebaseAnalytics _analytics;

  static const _currency = 'INR';

  @override
  void track(String event, {Map<String, Object?>? properties}) {
    unawaited(
      _analytics.logEvent(name: event, parameters: parametersFor(properties)),
    );

    // Then the GA4 STANDARD event for ★ events -> only those can be marked as an Ads conversion.
    switch (event) {
      case ArulEvents.loginSuccess:
        unawaited(
          _analytics.logLogin(loginMethod: properties?['provider'] as String?),
        );
      case 'checkout_started':
        // `begin_checkout` throws only on a value WITHOUT a currency -> pass INR unconditionally.
        unawaited(
          _analytics.logBeginCheckout(
            currency: _currency,
            value: _value(properties),
          ),
        );
      case ArulEvents.trialStarted:
      case ArulEvents.subscriptionActive:
        break;
    }
  }

  @override
  void identify(String userId, {Map<String, Object?>? userProperties}) {
    unawaited(_analytics.setUserId(id: userId));
  }

  @override
  void screen(String name, {Map<String, Object?>? properties}) {
    // No-op: GA4 auto-collects screen_view; PostHog owns explicit screens.
  }

  @override
  void reset() => unawaited(_analytics.setUserId(id: null));

  /// A GA4 USER property — the SDK stamps it on every event logged after it is set, which is the
  /// per-event cut [AnalyticsService.register] asks for. Invisible in reports until it is registered
  /// as a user-scoped custom dimension. Names ≤24 chars, values ≤36 -> a language code fits both.
  @override
  void register(String key, Object value) {
    if (kPostHogOnlyProperties.contains(key)) return;
    unawaited(_analytics.setUserProperty(name: key, value: value.toString()));
  }

  double? _value(Map<String, Object?>? props) {
    final v = props?['value'];
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }

  @visibleForTesting
  static Map<String, Object>? parametersFor(Map<String, Object?>? props) {
    if (props == null) return null;
    final out = <String, Object>{};
    props.forEach((key, value) {
      if (value == null || kPostHogOnlyProperties.contains(key)) return;
      out[key] = switch (value) {
        final bool b => b ? 1 : 0,
        String() || num() => value,
        _ => value.toString(),
      };
    });
    if (out.containsKey('value')) out.putIfAbsent('currency', () => _currency);
    return out.isEmpty ? null : out;
  }
}
