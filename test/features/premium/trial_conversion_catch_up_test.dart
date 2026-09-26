// TrialConversionCatchUp fires the late `trial_started` for trials granted with the app closed.
// A trialing row whose order this install never reported fires EXACTLY ONE event (order_id, value, late: true).
// An order the purchase notifier already reported, marked before the entitlement refresh, is never re-fired.
// A trial found before this install opened the marker began elsewhere (reinstall, second phone, update) -> recorded, not fired.
// A checkout on this install opens the marker, and a LATER order on the same install does fire.
// Non-trialing rows fire nothing and merely open the marker; the value never goes out empty.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:arul/core/analytics/analytics_service.dart';
import 'package:arul/data/models/app_config_model.dart';
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

  @override
  void register(String key, Object value) {}
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
    double price = 199,
  }) async {
    SharedPreferences.setMockInitialValues(stored);
    analytics = _RecordingAnalytics();
    return TrialConversionCatchUp(
      prefs: await SharedPreferences.getInstance(),
      analytics: analytics,
      monthlyPriceRupees: () => price,
    );
  }

  test('fires exactly one late trial_started for an unreported trialing order, '
      'with the in-session property shape plus late: true', () async {
    // '' = an earlier read saw no trial, or this install tapped checkout -> the trial is owed.
    final catchUp = await build(stored: {TrialConversionCatchUp.prefsKey: ''});

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

  test('the value falls back to the paywall price before app_config loads, '
      'and follows the config once it has', () {
    expect(monthlyPriceRupees(null), 199);
    const config = AppConfigModel(
      prices: {
        'monthly': {'amount': 14900},
      },
      policyUrls: {},
      featureFlags: {},
    );
    expect(monthlyPriceRupees(config), 149);
  });

  test(
    'never re-fires an order the purchase notifier already reported',
    () async {
      final catchUp = await build();

      // The notifier marks BEFORE it invalidates the entitlement -> the refresh that follows must see the mark.
      catchUp.markReported('DKS_ORDER_1');
      expect(catchUp.reconcile(_row(SubscriptionStatus.trialing)), isFalse);

      expect(analytics.events, isEmpty);
    },
  );

  test('a trial found before the marker opened is recorded, never fired — '
      'reinstall, second phone or update — then a later order fires', () async {
    // The install that ran this checkout already reported it; a second copy would credit this install's ad.
    final catchUp = await build();
    expect(catchUp.reconcile(_row(SubscriptionStatus.trialing)), isFalse);
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

  test('a checkout tapped before any entitlement read keeps its trial owed, '
      'so an app-closed grant still fires', () async {
    final catchUp = await build();
    catchUp.noteCheckout();
    expect(catchUp.reconcile(_row(SubscriptionStatus.trialing)), isTrue);
    expect(analytics.events.single.$2?['late'], isTrue);
  });

  test('a checkout never reopens a marker that already names an order', () async {
    final catchUp = await build(
      stored: {TrialConversionCatchUp.prefsKey: 'DKS_ORDER_1'},
    );
    catchUp.noteCheckout();
    expect(catchUp.isReported('DKS_ORDER_1'), isTrue);
    expect(catchUp.reconcile(_row(SubscriptionStatus.trialing)), isFalse);
    expect(analytics.events, isEmpty);
  });

  test('non-trialing rows fire nothing and initialise the marker, so a trial '
      'lost LATER on the same install is recognised as new', () async {
    final catchUp = await build();

    expect(catchUp.reconcile(const Entitlement.none()), isFalse);
    expect(catchUp.reconcile(_row(SubscriptionStatus.active)), isFalse);
    expect(catchUp.reconcile(_row(SubscriptionStatus.pending)), isFalse);
    expect(
      catchUp.reconcile(_row(SubscriptionStatus.trialing, orderId: null)),
      isFalse,
    );
    expect(analytics.events, isEmpty);

    // Marker now open (''), so the trial is owed, not found.
    expect(catchUp.reconcile(_row(SubscriptionStatus.trialing)), isTrue);
  });

  test('the marker survives in prefs under the arul_ key', () async {
    final catchUp = await build();
    catchUp.reconcile(_row(SubscriptionStatus.trialing));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(TrialConversionCatchUp.prefsKey), 'DKS_ORDER_1');
  });
}
