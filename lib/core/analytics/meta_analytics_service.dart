import 'dart:async';

import 'package:facebook_app_events/facebook_app_events.dart';

import 'analytics_events.dart';
import 'analytics_service.dart';

/// [AnalyticsService] backed by Meta App Events (Facebook SDK).
///
/// Meta is an *ad-optimisation* channel, not a product-analytics one.
/// The full firehose dilutes the signal its algorithm trains on -> [track] forwards ★ events ONLY:
///
///   login_success    → CompleteRegistration
///   checkout_started → InitiateCheckout (+ INR value when known → ROAS)
///   trial_started    → StartTrial       (+ INR value when known → ROAS)
///
/// **NO `Subscribe` EVENT IS SENT ANYWHERE** — not here, not from the Worker's Conversions API path.
/// The server sent `action_source: "system_generated"`, which Meta files under WEBSITE events.
/// So one conversion event arrived from TWO source types -> the campaign column lagged, raw counts did not.
/// A conversion event must have ONE source -> do NOT re-add Subscribe on either side.
/// **StartTrial (`start_trial_mobile_app`) is the ONLY event campaigns optimise on** — one source.
/// Trial→paid is ~84% -> bidding on it loses no signal; the accepted cost is no ROAS signal.
/// Neon is revenue truth.
/// `checkout_started` is the one NON-terminal event — Meta's only signal at the UPI mandate handoff.
/// That handoff is where most of this funnel is lost (docs/edge-cases.md).
/// `payment_failed` is a diagnostic, not a conversion -> forwarding it trains the optimiser wrong.
/// App install and launch are auto-logged by the native SDK -> never log them here.
/// [screen] is a no-op; [identify] feeds advanced matching; [reset] clears the id on sign-out.
/// Fire-and-forget, and only selected with a real App ID + client token -> tests never touch the SDK.
class MetaAnalyticsService implements AnalyticsService {
  MetaAnalyticsService([FacebookAppEvents? facebook])
    : _facebook = facebook ?? FacebookAppEvents();

  final FacebookAppEvents _facebook;

  /// Currency for all valued conversion events. India-only (v1) → INR.
  static const _currency = 'INR';

  @override
  void track(String event, {Map<String, Object?>? properties}) {
    switch (event) {
      case ArulEvents.loginSuccess:
        unawaited(
          _facebook.logCompletedRegistration(
            registrationMethod: properties?['provider'] as String?,
          ),
        );
      case 'checkout_started':
        unawaited(
          _facebook.logInitiatedCheckout(
            // valueToSum + currency TOGETHER are what make this eligible for ROAS optimisation.
            totalPrice: _value(properties),
            currency: _currency,
            contentType: 'subscription',
            contentId: properties?['plan'] as String?,
            numItems: 1,
            // PhonePe owns the payment screen -> nothing is collected in-app -> honestly false.
            paymentInfoAvailable: false,
          ),
        );
      case ArulEvents.trialStarted:
        unawaited(
          _facebook.logStartTrial(
            orderId: _orderId(properties),
            price: _value(properties),
            currency: _currency,
          ),
        );
      // `subscription_active` deliberately emits NOTHING — see the class doc.
      // Every other product event stays PostHog-only — intentionally dropped.
    }
  }

  @override
  void identify(String userId, {Map<String, Object?>? userProperties}) {
    // Advanced matching — the SDK hashes the id before upload; cheap, and improves attribution.
    unawaited(_facebook.setUserID(userId));
  }

  @override
  void screen(String name, {Map<String, Object?>? properties}) {
    // No-op: screen views are a PostHog concern, not an ad-conversion signal.
  }

  @override
  void reset() => unawaited(_facebook.clearUserID());

  /// Meta's StartTrial wants a NON-EMPTY `orderId` -> the PhonePe merchant order id, else a fallback.
  /// Meta-side dedup is best-effort only.
  String _orderId(Map<String, Object?>? props) {
    final id = props?['order_id'];
    if (id is String && id.isNotEmpty) return id;
    return 'unknown';
  }

  /// Revenue for ROAS. `value` may be a num or a numeric string -> null when absent, event still logs.
  double? _value(Map<String, Object?>? props) {
    final v = props?['value'];
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }
}
