import 'dart:async';

import 'package:firebase_analytics/firebase_analytics.dart';

import 'analytics_events.dart';
import 'analytics_service.dart';

/// [AnalyticsService] backed by Firebase Analytics (Google Analytics 4).
///
/// Two jobs: product analytics (EVERY event is forwarded) and the conversion source for Google Ads.
/// Ads cannot ingest app conversions directly -> it reads them from a linked GA4 property.
/// So ★ events ALSO map onto GA4 *standard* events, emitted IN ADDITION to the raw-named one:
///
///   login_success    → login          (standard)
///   checkout_started → begin_checkout (standard, value+INR)
///
/// **NO `purchase` EVENT IS EMITTED ANYWHERE**, client or server (owner's call).
/// It was split by settle location -> ONE conversion action fed by the app SDK AND the server MP.
/// Two source types desynchronise attribution -> the campaign column lagged, raw counts looked right.
/// A conversion action must have ONE data source -> keep `purchase` UNMARKED in GA4 and OUT of Ads.
/// `trial_started` is the ONLY key event imported into Ads — app-SDK-sourced, in-session, one source.
/// Trial→paid is ~84% -> bidding on it loses no signal; the accepted cost is no ROAS signal in Ads.
/// Neon is revenue truth — it always was.
/// GA4 auto-collects `first_open`, `session_start` and `screen_view` -> [screen] is a no-op here.
/// Fire-and-forget; selected only when Firebase is enabled -> tests never touch the platform channel.
/// The SDK needs snake_case names ≤40 chars and String/num values -> [_clean] coerces, never rejects.
class GoogleAnalyticsService implements AnalyticsService {
  GoogleAnalyticsService([FirebaseAnalytics? analytics])
    : _analytics = analytics ?? FirebaseAnalytics.instance;

  final FirebaseAnalytics _analytics;

  /// Currency for valued conversion events. India-only (v1) → INR.
  static const _currency = 'INR';

  @override
  void track(String event, {Map<String, Object?>? properties}) {
    // Always log the raw event, for product-analytics parity.
    unawaited(_analytics.logEvent(name: event, parameters: _clean(properties)));

    // Then the GA4 STANDARD event for ★ events -> only those can be marked as an Ads conversion.
    switch (event) {
      case ArulEvents.loginSuccess:
        unawaited(
          _analytics.logLogin(loginMethod: properties?['provider'] as String?),
        );
      case 'checkout_started':
        // The mid-funnel standard event.
        // `begin_checkout` throws only on a value WITHOUT a currency -> pass INR unconditionally.
        unawaited(
          _analytics.logBeginCheckout(
            currency: _currency,
            value: _value(properties),
          ),
        );
      // A trial moves no money and `purchase` is REMOVED everywhere -> neither emits a standard event.
      // The raw `trial_started` above carries value/plan/order_id and is the ONLY key event for Ads.
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
  void reset() => unawaited(_analytics.resetAnalyticsData());

  /// Revenue for Google Ads ROAS. `value` may be a num or a numeric string; null when absent.
  double? _value(Map<String, Object?>? props) {
    final v = props?['value'];
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }

  /// GA4 accepts only non-null String/num values -> drop nulls, coerce bools, stringify the rest.
  /// A stray value type would otherwise reject the WHOLE event. An empty or absent map -> null.
  /// GA4 DISCARDS `value` unless `currency` rides with it — the amount is stripped as `_err=19`.
  /// A valued event then reaches Google Ads carrying no revenue at all.
  /// India-only -> pair every `value` with INR HERE, not at each call site; explicit `currency` wins.
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
    if (out.containsKey('value')) out.putIfAbsent('currency', () => _currency);
    return out.isEmpty ? null : out;
  }
}
