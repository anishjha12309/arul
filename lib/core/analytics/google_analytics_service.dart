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
///        trial_started       → (none — see below)
///        subscription_active → purchase (standard, value+INR → Google Ads ROAS)
///      (We emit the standard event IN ADDITION to the raw-named event, so the
///      console shows both the product event and the conversion.)
///
///      **`purchase` is reserved for money that actually moved.** A trial debits
///      nothing, so mapping it to `purchase` booked phantom revenue and counted
///      one subscriber twice — once at trial start, again on conversion. The raw
///      `trial_started` event (logged above, with `value`/`plan`/`order_id`) is
///      itself markable as a GA4 key event and importable into Google Ads, so
///      trial optimisation keeps a conversion to bid on without polluting ROAS.
///
///      CAVEAT — trial→paid is invisible here. `subscription_active` only fires
///      when the purchase flow itself returns `active` (a repeat subscriber
///      paying ₹199 upfront). A trial that converts later does so server-side
///      with the app closed, so no client event exists for it. Until the Worker
///      reports that conversion via the GA4 Measurement Protocol, `purchase`
///      under-reports trial-originated revenue — Neon remains revenue truth.
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
      // Deliberately NOT mapped to `purchase` — a trial moves no money. The
      // raw `trial_started` logged above carries value/plan/order_id and is
      // the event to mark as a key event for trial-optimised Ads bidding.
      case 'trial_started':
        break;
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
