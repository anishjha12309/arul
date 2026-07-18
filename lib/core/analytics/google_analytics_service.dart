import 'dart:async';

import 'package:firebase_analytics/firebase_analytics.dart';

import 'analytics_service.dart';

/// [AnalyticsService] backed by Firebase Analytics (Google Analytics 4).
///
/// GA4-for-apps serves two jobs here:
///   1. Product analytics in the Firebase/GA4 console (parity with PostHog) —
///      so EVERY event is forwarded via [FirebaseAnalytics.logEvent].
///   2. The **conversion source for Google Ads**. Google Ads can't ingest app
///      conversions directly; it reads them from a linked GA4 property. So the
///      ★ conversion events ALSO map onto GA4 *standard* events, which are the
///      ones eligible to be marked as Google Ads conversions:
///        login_success       → login    (standard)
///        trial_started       → purchase (standard, value+INR → Google Ads ROAS)
///        subscription_active → purchase (standard, value+INR → Google Ads ROAS)
///      (We emit the standard event IN ADDITION to the raw-named event, so the
///      console shows both the product event and the conversion.)
///
/// GA4 auto-collects `first_open`, `session_start`, and `screen_view`, so we
/// don't log app-launch here. [screen] is a no-op for the same reason (PostHog
/// owns screen semantics; GA4's automatic screen tracking covers the rest).
///
/// All calls are fire-and-forget — the SDK batches + uploads in the background.
/// Only selected when Firebase is enabled (real build, not `flutter test` — see
/// `analytics_provider.dart` / `AppConfig.firebaseEnabled`), so tests never
/// touch the platform channel.
///
/// GA4 naming rules enforced by the SDK: event + parameter names must be
/// snake_case (≤40 chars) and parameter values must be String/num. Our event
/// names are already snake_case; [_clean] drops nulls and coerces bools so an
/// event is never silently rejected.
class GoogleAnalyticsService implements AnalyticsService {
  GoogleAnalyticsService([FirebaseAnalytics? analytics])
    : _analytics = analytics ?? FirebaseAnalytics.instance;

  final FirebaseAnalytics _analytics;

  /// Currency for valued conversion events. India-only (v1) → INR.
  static const _currency = 'INR';

  @override
  void track(String event, {Map<String, Object?>? properties}) {
    // 1. Always log the raw event for product-analytics parity.
    unawaited(_analytics.logEvent(name: event, parameters: _clean(properties)));

    // 2. Additionally emit the GA4 standard conversion event for ★ events, so
    //    it can be marked as a Google Ads conversion.
    switch (event) {
      case 'login_success':
        unawaited(
          _analytics.logLogin(loginMethod: properties?['provider'] as String?),
        );
      case 'trial_started':
      case 'subscription_active':
        unawaited(
          _analytics.logPurchase(
            currency: _currency,
            value: _value(properties),
          ),
        );
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
  void reset() => unawaited(_analytics.resetAnalyticsData());

  /// Revenue for Google Ads ROAS. `value` may be a num or numeric string;
  /// null when absent (the purchase event still logs, just without value).
  double? _value(Map<String, Object?>? props) {
    final v = props?['value'];
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }

  /// GA4 accepts only non-null String/num parameter values. Drop nulls, coerce
  /// bools to 1/0, keep String/num, and stringify anything else so a stray
  /// value type can't cause the whole event to be rejected. Returns null for an
  /// empty/absent map.
  Map<String, Object>? _clean(Map<String, Object?>? props) {
    if (props == null) return null;
    final out = <String, Object>{};
    props.forEach((key, value) {
      if (value == null) return;
      out[key] = switch (value) {
        final bool b => b ? 1 : 0,
        String() || num() => value,
        _ => value.toString(),
      };
    });
    return out.isEmpty ? null : out;
  }
}
