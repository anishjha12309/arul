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
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:arul/core/analytics/analytics_provider.dart';
import 'package:arul/core/analytics/analytics_service.dart';
import 'package:arul/core/api/api_client.dart';
import 'package:arul/data/models/app_config_model.dart';
import 'package:arul/data/repositories/repository_providers.dart';
import 'package:arul/features/auth/providers/auth_providers.dart';
import 'package:arul/features/premium/domain/entitlement.dart';
import 'package:arul/features/premium/providers/entitlement_provider.dart';
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
  _FakeApi(this.statuses, {this.throwOnStatus = false});

  final List<String> statuses;

  /// Every `/payments/status` dies before reaching the server — the poll
  /// riding a dead radio behind the UPI app.
  final bool throwOnStatus;
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
        if (throwOnStatus) throw const SocketException('Failed host lookup');
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
    List<Override> overrides = const [],
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
        ...overrides,
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

  // The everyday path: the user stays on the paywall until the mandate settles.
  // REGRESSION GUARD — the three tests above all run with the notifier already
  // disposed, so `ref.mounted` is false in every guard and the mounted branch
  // was never executed. A `_refreshEntitlement()` that recursed into itself
  // therefore passed the whole suite while, on a real device, it threw
  // StackOverflowError inside the poll's catch-all, swallowed the success, and
  // showed "Payment received but confirmation is delayed" over a live mandate
  // (device 2026-08-26). Any helper guarded by `ref.mounted` needs a mounted
  // test or it is untested where it matters.
  testWidgets(
    'paywall still open: a settle flips to success and re-reads entitlement',
    (tester) async {
      final api = _FakeApi(['trialing']);
      var entitlementBuilds = 0;
      final container = await build(
        tester,
        api,
        overrides: [
          entitlementDetailProvider.overrideWith((ref) async {
            entitlementBuilds++;
            return const Entitlement(isPremium: false);
          }),
        ],
      );
      final purchaseSub = container.listen(premiumPurchaseProvider, (_, _) {});
      addTearDown(purchaseSub.close);
      // Keep entitlement alive, so an invalidation actually rebuilds it.
      final entSub = container.listen(entitlementDetailProvider, (_, _) {});
      addTearDown(entSub.close);
      await container.read(entitlementDetailProvider.future);
      final buildsBefore = entitlementBuilds;

      unawaited(
        container
            .read(premiumPurchaseProvider.notifier)
            .startTrial(targetApp: 'com.phonepe.app'),
      );
      await tester.pump(const Duration(seconds: 30));

      expect(
        container.read(premiumPurchaseProvider),
        isA<PurchaseSuccess>(),
        reason: 'the success branch must survive with the paywall mounted',
      );
      expect(
        entitlementBuilds,
        greaterThan(buildsBefore),
        reason: 'entitlement must be re-read so the UI flips to member view',
      );
      expect(eventsNamed('trial_started'), hasLength(1));
    },
  );

  // ── The defect that started the 2026-08-26 incident ───────────────────────
  // The payment succeeds server-side while the app's polls die on a torn-down
  // radio behind the UPI app. The app gives up with "confirmation is delayed"
  // — and used to leave the pre-purchase entitlement snapshot in place, so the
  // paywall still read "Start free trial" to a user who WAS premium. The owner
  // hit exactly that, concluded the payment had failed while autopay was armed,
  // and revoked a live mandate from their UPI app.
  testWidgets(
    'an unreachable confirmation re-reads entitlement so the UI self-corrects',
    (tester) async {
      final api = _FakeApi(const ['pending'], throwOnStatus: true);
      var entitlementBuilds = 0;
      final container = await build(
        tester,
        api,
        overrides: [
          entitlementDetailProvider.overrideWith((ref) async {
            entitlementBuilds++;
            return const Entitlement(isPremium: false);
          }),
        ],
      );
      final purchaseSub = container.listen(premiumPurchaseProvider, (_, _) {});
      addTearDown(purchaseSub.close);
      final entSub = container.listen(entitlementDetailProvider, (_, _) {});
      addTearDown(entSub.close);
      await container.read(entitlementDetailProvider.future);
      final buildsBefore = entitlementBuilds;

      unawaited(
        container
            .read(premiumPurchaseProvider.notifier)
            .startTrial(targetApp: 'com.phonepe.app'),
      );
      // The intent budget is ~2 minutes of backoff; outlast it.
      await tester.pump(const Duration(seconds: 200));

      expect(container.read(premiumPurchaseProvider), isA<PurchaseError>());
      expect(
        eventsNamed('payment_failed').single?['reason'],
        'confirmation_unreachable',
        reason: 'never reached the server — must not claim a real declination',
      );
      expect(
        entitlementBuilds,
        greaterThan(buildsBefore),
        reason:
            'entitlement must be re-read so a granted trial surfaces itself',
      );
    },
  );

  // Coming back from the UPI app without paying is the COMMON case, so the
  // checkpoint must resolve at network speed — no timed grace of any size.
  // Two have been tried and both were rejected on device: a 14 s ladder, then
  // a 2 s beat. Production tails on 2026-08-26 showed why neither earned its
  // keep — PhonePe still reported the order PENDING at every sample, so the
  // extra polls returned exactly what the first one did and the abandon ran
  // anyway.
  //
  // Nothing is lost by resolving immediately: `/payments/abandon` re-reads the
  // LIVE order and answers settled:true rather than expiring one PhonePe says
  // COMPLETED, and the setup webhook resurrects an approval that races the
  // release. This test is the guard on that — re-introduce a delay of even one
  // second and the short pump below leaves the flow unresolved.
  testWidgets('resume checkpoint resolves without waiting out any grace', (
    tester,
  ) async {
    final api = _FakeApi(const ['pending']);
    final container = await build(tester, api);
    final purchaseSub = container.listen(premiumPurchaseProvider, (_, _) {});
    addTearDown(purchaseSub.close);

    unawaited(
      container
          .read(premiumPurchaseProvider.notifier)
          .startTrial(targetApp: 'com.phonepe.app'),
    );
    await tester.pump(const Duration(milliseconds: 10));
    expect(container.read(premiumPurchaseProvider), isA<PurchaseProcessing>());

    // The user returns from the UPI app without approving.
    unawaited(
      container.read(premiumPurchaseProvider.notifier).pollNowOnResume(),
    );
    // Far shorter than any grace that has ever been in this method.
    await tester.pump(const Duration(milliseconds: 200));

    expect(
      api.abandons,
      1,
      reason: 'the claim must be released immediately, not after a wait',
    );
    expect(container.read(premiumPurchaseProvider), isA<PurchaseError>());

    // Drain the background intent poll. Resolving above SILENCED it (via
    // _pollGeneration) rather than cancelling its timers, so without this the
    // harness fails the test for leaving one pending — which would bury the
    // two assertions that actually matter.
    await tester.pump(const Duration(seconds: 200));
  });
}
