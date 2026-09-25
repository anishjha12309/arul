import 'dart:async';

import 'package:facebook_app_events/facebook_app_events.dart';

import 'analytics_events.dart';
import 'analytics_service.dart';

class MetaAnalyticsService implements AnalyticsService {
  MetaAnalyticsService([FacebookAppEvents? facebook])
    : _facebook = facebook ?? FacebookAppEvents();

  final FacebookAppEvents _facebook;

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

  /// No-op: Meta receives three ★ events and no product cuts are read there.
  @override
  void register(String key, Object value) {}

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
