// Tests for the purchase notifier OUTLIVING the paywall. The contracts:
//   - a status poll still running when the paywall is popped (autoDispose)
//     finishes on the dead ref WITHOUT throwing, and a mandate that settles
//     then still fires `trial_started` (order id + value) and marks the order
//     reported. This was the "Cannot use the Ref of premiumPurchaseProvider
//     after it has been disposed" crash (671 users / 30 days, 2026-08-26),
//     which threw BEFORE the conversion was tracked;
//   - an order the catch-up already reported is never counted twice;
//   - a failure after the paywall is gone still counts `payment_failed`.
//
// The payment sequence itself (initiate → launch → poll → settle/expire) is
// asserted by call counts so a guard can never change WHEN the server is
// asked, only whether a dead screen is repainted.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:arul/core/analytics/analytics_provider.dart';
import 'package:arul/core/analytics/analytics_service.dart';
import 'package:arul/core/api/api_client.dart';
import 'package:arul/data/models/app_config_model.dart';
import 'package:arul/data/repositories/repository_providers.dart';
import 'package:arul/features/auth/providers/auth_providers.dart';
import 'package:arul/features/premium/providers/premium_purchase_provider.dart';
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

/// Answers the three purchase endpoints in memory. `/payments/status` walks
/// [statuses] one per call and repeats the last one.
class _FakeApi extends ApiClient {
  _FakeApi(this.statuses);

  final List<String> statuses;
  int statusCalls = 0;
  int abandons = 0;

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Map<String, dynamic>? body,
    bool requiresAuth = true,
  }) async {
    switch (path) {
      case '/payments/initiate':
        return {
          'merchantOrderId': 'DKS_ORDER_1',
          'intentUrl': 'upi://mandate?tr=1',
        };
      case '/payments/status':
        final i = statusCalls++;
        return {
          'status': statuses[i < statuses.length ? i : statuses.length - 1],
        };
      case '/payments/abandon':
        abandons++;
        return {'settled': false};
    }
    throw StateError('unexpected POST $path');
  }
}

const _upiChannel = MethodChannel('com.hsrutility.arul/upi_intent');

void main() {
  late _RecordingAnalytics analytics;
  late SharedPreferences prefs;

  Future<ProviderContainer> build(
    WidgetTester tester,
    _FakeApi api, {
    Map<String, Object> stored = const {},
  }) async {
    SharedPreferences.setMockInitialValues(stored);
    prefs = await SharedPreferences.getInstance();
    analytics = _RecordingAnalytics();
    // The chosen UPI app "opens" — the intent path's only native step.
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      _upiChannel,
      (call) async => call.method == 'launch',
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        _upiChannel,
        null,
      ),
    );
    final container = ProviderContainer(
      overrides: [
        apiClientProvider.overrideWith((ref) => api),
        analyticsServiceProvider.overrideWith((ref) => analytics),
        appConfigProvider.overrideWith(
          (ref) async => const AppConfigModel(
            prices: {
              'monthly': {'amount': 19900},
            },
            policyUrls: <String, dynamic>{},
            featureFlags: <String, dynamic>{},
          ),
        ),
        trialConversionCatchUpProvider.overrideWithValue(
          TrialConversionCatchUp(
            prefs: prefs,
            analytics: analytics,
            monthlyPriceRupees: () => 199,
            isFreshInstall: true,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    // The paywall has the price on screen before the tap.
    await container.read(appConfigProvider.future);
    return container;
  }

  /// Taps "start trial" on the UPI-intent path, waits until the app is polling,
  /// then pops the paywall — dropping the only listener, which autoDisposes
  /// the notifier while its poll is mid-flight.
  Future<void> startThenLeave(
    WidgetTester tester,
    ProviderContainer container,
  ) async {
    final sub = container.listen(premiumPurchaseProvider, (_, _) {});
    unawaited(
      container
          .read(premiumPurchaseProvider.notifier)
          .startTrial(targetApp: 'com.phonepe.app'),
    );
    await tester.pump(const Duration(milliseconds: 10));
    expect(container.read(premiumPurchaseProvider), isA<PurchaseProcessing>());
    sub.close();
    await tester.pump(const Duration(milliseconds: 10));
  }

  List<Map<String, Object?>?> eventsNamed(String name) =>
      analytics.events.where((e) => e.$1 == name).map((e) => e.$2).toList();

  testWidgets(
    'a poll that outlives the paywall still fires trial_started, once',
    (tester) async {
      final api = _FakeApi(['pending', 'pending', 'trialing']);
      final container = await build(tester, api);
      await startThenLeave(tester, container);

      // Intent-path poll delays are 4, 4, 4 s before the third answer settles.
      await tester.pump(const Duration(seconds: 30));

      expect(api.statusCalls, 3, reason: 'settled on the third poll, stopped');
      expect(api.abandons, 0);
      expect(eventsNamed('trial_started'), [
        {'plan': 'monthly', 'order_id': 'DKS_ORDER_1', 'value': 199.0},
      ]);
      expect(prefs.getString(TrialConversionCatchUp.prefsKey), 'DKS_ORDER_1');
      expect(eventsNamed('checkout_started'), hasLength(1));
      expect(eventsNamed('payment_failed'), isEmpty);
    },
  );

  testWidgets('an order the catch-up already reported is not counted twice', (
    tester,
  ) async {
    final api = _FakeApi(['trialing']);
    final container = await build(
      tester,
      api,
      stored: {TrialConversionCatchUp.prefsKey: 'DKS_ORDER_1'},
    );
    await startThenLeave(tester, container);
    await tester.pump(const Duration(seconds: 30));

    expect(api.statusCalls, 1);
    expect(eventsNamed('trial_started'), isEmpty);
  });

  testWidgets(
    'a failure after the paywall is gone still counts payment_failed',
    (tester) async {
      final api = _FakeApi(['pending', 'expired']);
      final container = await build(tester, api);
      await startThenLeave(tester, container);
      await tester.pump(const Duration(seconds: 30));

      expect(api.statusCalls, 2);
      expect(eventsNamed('trial_started'), isEmpty);
      expect(eventsNamed('payment_failed'), [
        {
          'reason': 'expired',
          'cancelled': false,
          'plan': 'monthly',
          'method': 'upi_app',
        },
      ]);
    },
  );
}
