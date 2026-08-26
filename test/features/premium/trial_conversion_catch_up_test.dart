// Tests for TrialConversionCatchUp — the late `trial_started` for trials that
// were granted with the app closed. The contracts under guard:
//   - a trialing row whose order this install never reported fires EXACTLY
//     ONE `trial_started` (order_id, value, late: true), and never again;
//   - an order the purchase notifier already reported (markReported before the
//     entitlement refresh) is never re-fired;
//   - an install that predates the catch-up grandfathers the trial it finds on
//     first run (no fire — it may have fired on the old build), but a LATER
//     order on the same install does fire;
//   - a fresh install has no such history and fires on first run;
//   - non-trialing rows fire nothing and merely initialise the marker.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:arul/core/analytics/analytics_service.dart';
import 'package:arul/data/models/subscription_model.dart';
import 'package:arul/features/premium/domain/entitlement.dart';
import 'package:arul/features/premium/providers/trial_conversion_catch_up.dart';

class _RecordingAnalytics implements AnalyticsService {
  final events = <(String, Map<String, Object?>?)>[];

  @override
  void track(String event, {Map<String, Object?>? properties}) =>
      events.add((event, properties));

  @override
  void identify(String userId, {Map<String, Object?>? userProperties}) {}

  @override
  void screen(String name, {Map<String, Object?>? properties}) {}

  @override
  void reset() {}
}

Entitlement _row(SubscriptionStatus status, {String? orderId = 'DKS_ORDER_1'}) {
  return Entitlement(
    isPremium: status == SubscriptionStatus.trialing,
    subscription: SubscriptionModel(
      id: 'sub-1',
      userId: 'user-1',
      status: status,
      merchantOrderId: orderId,
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _RecordingAnalytics analytics;

  Future<TrialConversionCatchUp> build({
    Map<String, Object> stored = const {},
    bool isFreshInstall = true,
    double? price = 199,
  }) async {
    SharedPreferences.setMockInitialValues(stored);
    analytics = _RecordingAnalytics();
    return TrialConversionCatchUp(
      prefs: await SharedPreferences.getInstance(),
      analytics: analytics,
      monthlyPriceRupees: () => price,
      isFreshInstall: isFreshInstall,
    );
  }

  test('fires exactly one late trial_started for an unreported trialing order, '
      'with the in-session property shape plus late: true', () async {
    final catchUp = await build();

    expect(catchUp.reconcile(_row(SubscriptionStatus.trialing)), isTrue);
    expect(catchUp.reconcile(_row(SubscriptionStatus.trialing)), isFalse);

    expect(analytics.events, hasLength(1));
    final (event, properties) = analytics.events.single;
    expect(event, 'trial_started');
    expect(properties, {
      'plan': 'monthly',
      'order_id': 'DKS_ORDER_1',
      'value': 199,
      'late': true,
    });
  });

  test(
    'omits value when the price has not loaded, like the in-session event',
    () async {
      final catchUp = await build(price: null);
      catchUp.reconcile(_row(SubscriptionStatus.trialing));
      expect(analytics.events.single.$2, isNot(contains('value')));
    },
  );

  test(
    'never re-fires an order the purchase notifier already reported',
    () async {
      final catchUp = await build();

      // The notifier marks BEFORE it invalidates the entitlement; the refresh
      // that follows must see the mark.
      catchUp.markReported('DKS_ORDER_1');
      expect(catchUp.reconcile(_row(SubscriptionStatus.trialing)), isFalse);

      expect(analytics.events, isEmpty);
    },
  );

  test('an install that predates the catch-up grandfathers the trial it finds, '
      'then fires for a later order', () async {
    // No marker ever written + not a fresh install = the old build may already
    // have fired this one. Record it, do not fire.
    final catchUp = await build(isFreshInstall: false);
    expect(catchUp.reconcile(_row(SubscriptionStatus.trialing)), isFalse);
    expect(analytics.events, isEmpty);

    // A different trialing order later (second account on the device) is new.
    expect(
      catchUp.reconcile(
        _row(SubscriptionStatus.trialing, orderId: 'DKS_ORDER_2'),
      ),
      isTrue,
    );
    expect(analytics.events.single.$2?['order_id'], 'DKS_ORDER_2');
  });

  test(
    'a fresh install has no old-build history and fires on first run',
    () async {
      final catchUp = await build(isFreshInstall: true);
      expect(catchUp.reconcile(_row(SubscriptionStatus.trialing)), isTrue);
    },
  );

  test('non-trialing rows fire nothing and initialise the marker, so a trial '
      'lost LATER on a pre-existing install is recognised as new', () async {
    final catchUp = await build(isFreshInstall: false);

    expect(catchUp.reconcile(const Entitlement.none()), isFalse);
    expect(catchUp.reconcile(_row(SubscriptionStatus.active)), isFalse);
    expect(catchUp.reconcile(_row(SubscriptionStatus.pending)), isFalse);
    expect(
      catchUp.reconcile(_row(SubscriptionStatus.trialing, orderId: null)),
      isFalse,
    );
    expect(analytics.events, isEmpty);

    // Marker now exists (''), so the grandfather branch no longer applies.
    expect(catchUp.reconcile(_row(SubscriptionStatus.trialing)), isTrue);
  });

  test('the marker survives in prefs under the arul_ key', () async {
    final catchUp = await build();
    catchUp.reconcile(_row(SubscriptionStatus.trialing));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(TrialConversionCatchUp.prefsKey), 'DKS_ORDER_1');
  });
}
