import 'dart:async';

import 'package:facebook_app_events/facebook_app_events.dart';

import 'analytics_service.dart';

/// [AnalyticsService] backed by Meta App Events (Facebook SDK).
///
/// UNLIKE [PostHogAnalyticsService], this does NOT forward every event. Meta is
/// an *ad-optimisation* channel, not a product-analytics one: sending the full
/// firehose would only dilute the conversion signal its algorithm trains on (and
/// widen the privacy surface). So [track] maps ONLY the ★ conversion events from
/// `docs/analytics-events.md` onto Meta standard events and drops the rest:
///
///   login_success        → CompleteRegistration
///   trial_started        → StartTrial      (+ INR value when known → ROAS)
///   subscription_active  → Subscribe       (+ INR value when known → ROAS)
///
/// App install + launch are logged automatically by the native SDK
/// (`AutoInitEnabled` + `AutoLogAppEventsEnabled` in AndroidManifest.xml), so we
/// never log those here.
///
/// [screen] is a no-op (screen views belong in PostHog). [identify] forwards the
/// user id for Meta advanced matching; [reset] clears it on sign-out.
///
/// All calls are fire-and-forget — the SDK batches + uploads in the background —
/// so the UI path is never blocked, matching the PostHog impl. It is only
/// selected when a real App ID + client token are configured (see
/// `analytics_provider.dart` / `AppConfig.metaEnabled`), so tests and key-less
/// dev builds never touch the SDK.
class MetaAnalyticsService implements AnalyticsService {
  MetaAnalyticsService([FacebookAppEvents? facebook])
    : _facebook = facebook ?? FacebookAppEvents();

  final FacebookAppEvents _facebook;

  /// Currency for all valued conversion events. India-only (v1) → INR.
  static const _currency = 'INR';

  @override
  void track(String event, {Map<String, Object?>? properties}) {
    switch (event) {
      case 'login_success':
        unawaited(
          _facebook.logCompletedRegistration(
            registrationMethod: properties?['provider'] as String?,
          ),
        );
      case 'trial_started':
        unawaited(
          _facebook.logStartTrial(
            orderId: _orderId(properties),
            price: _value(properties),
            currency: _currency,
          ),
        );
      case 'subscription_active':
        unawaited(
          _facebook.logSubscribe(
            orderId: _orderId(properties),
            price: _value(properties),
            currency: _currency,
          ),
        );
      // Every other product event stays PostHog-only — intentionally dropped.
    }
  }

  @override
  void identify(String userId, {Map<String, Object?>? userProperties}) {
    // Advanced matching: associate Meta events with our user id. Cheap and
    // improves attribution; the SDK hashes it before upload.
    unawaited(_facebook.setUserID(userId));
  }

  @override
  void screen(String name, {Map<String, Object?>? properties}) {
    // No-op: screen views are a PostHog concern, not an ad-conversion signal.
  }

  @override
  void reset() => unawaited(_facebook.clearUserID());

  /// Meta's StartTrial/Subscribe want a non-empty `orderId`. Use the PhonePe
  /// merchant order id when the caller supplies one, else a stable fallback so
  /// the event is still accepted (dedup on Meta's side is best-effort only).
  String _orderId(Map<String, Object?>? props) {
    final id = props?['order_id'];
    if (id is String && id.isNotEmpty) return id;
    return 'unknown';
  }

  /// Revenue for ROAS optimisation. Accepts a `value` property as num or a
  /// numeric string; returns null when absent so the event still logs (just
  /// without a value-to-sum).
  double? _value(Map<String, Object?>? props) {
    final v = props?['value'];
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }
}
