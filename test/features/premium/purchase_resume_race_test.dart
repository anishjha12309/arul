// A resume re-polls the SAME order, so its id cannot tell the live poll from the one it replaced.
// Each test wakes a superseded poll, status answer or abandon AFTER the person moved on, and asserts
// it leaves the newer attempt, and that attempt's return from the UPI app, alone.

import 'dart:async';

import 'package:arul/core/analytics/analytics_provider.dart';
import 'package:arul/core/analytics/analytics_service.dart';
import 'package:arul/core/api/api_client.dart';
import 'package:arul/core/providers/shared_preferences_provider.dart';
import 'package:arul/data/models/app_config_model.dart';
import 'package:arul/data/repositories/repository_providers.dart';
import 'package:arul/features/auth/providers/auth_providers.dart';
import 'package:arul/features/premium/domain/cancel_offer.dart';
import 'package:arul/features/premium/providers/premium_purchase_provider.dart';
import 'package:arul/features/premium/providers/trial_conversion_catch_up.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

// Every initiate opens a NEW order. A set `heldStatus` or `heldAbandon` keeps the NEXT such call on
// the wire until the test answers it.
class _FakeApi extends ApiClient {
  int initiates = 0;
  int abandons = 0;
  String status = 'pending';
  Completer<Map<String, dynamic>>? heldStatus;
  Completer<void>? heldAbandon;

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Map<String, dynamic>? body,
    bool requiresAuth = true,
    bool withToken = true,
    Duration? timeout,
  }) async {
    switch (path) {
      case '/payments/initiate':
        final id = 'DKS_ORDER_${++initiates}';
        if (body?['targetApp'] == null) {
          return {
            'merchantOrderId': id,
            'orderId': 'OMO_$initiates',
            'token': 'token',
            'merchantId': 'MERCHANT',
            'environment': 'SANDBOX',
          };
        }
        return {
          'merchantOrderId': id,
          'intentUrl': 'upi://mandate?tr=$id&am=2',
        };
      case '/payments/status':
        final held = heldStatus;
        if (held != null) {
          heldStatus = null;
          return held.future;
        }
        return {'status': status};
      case '/payments/abandon':
        abandons++;
        final held = heldAbandon;
        if (held != null) {
          heldAbandon = null;
          await held.future;
        }
        return {'settled': false};
    }
    throw StateError('unexpected POST $path');
  }
}

const _upiChannel = MethodChannel('com.hsrutility.arul/upi_intent');
const _sdkChannel = MethodChannel('phonepe_payment_sdk');
const _phonePe = 'com.phonepe.app';
const _gpay = 'com.google.android.apps.nbu.paisa.user';

void main() {
  late _RecordingAnalytics analytics;
  late _FakeApi api;
  late List<Map<Object?, Object?>> launches;
  late Completer<Map<Object?, Object?>?> sdkResult;

  Future<ProviderContainer> build(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    analytics = _RecordingAnalytics();
    api = _FakeApi();
    launches = [];
    sdkResult = Completer();
    PremiumPurchase.clock = () => tester.binding.clock.now();
    addTearDown(() => PremiumPurchase.clock = DateTime.now);

    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_upiChannel, (call) async {
      if (call.method != 'launch') return null;
      launches.add(call.arguments as Map<Object?, Object?>);
      return true;
    });
    messenger.setMockMethodCallHandler(_sdkChannel, (call) async {
      if (call.method == 'init') return true;
      if (call.method == 'startTransaction') return sdkResult.future;
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(_upiChannel, null);
      messenger.setMockMethodCallHandler(_sdkChannel, null);
    });

    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        apiClientProvider.overrideWith((ref) => api),
        analyticsServiceProvider.overrideWith((ref) => analytics),
        appConfigProvider.overrideWithBuild(
          (ref, _) async => const AppConfigModel(
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
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    // The paywall is open throughout.
    final sub = container.listen(premiumPurchaseProvider, (_, _) {});
    addTearDown(sub.close);
    await container.read(appConfigProvider.future);
    return container;
  }

  PremiumPurchase notifierOf(ProviderContainer c) =>
      c.read(premiumPurchaseProvider.notifier);

  PurchaseState stateOf(ProviderContainer c) => c.read(premiumPurchaseProvider);

  List<Object?> failureReasons() => [
    for (final (name, props) in analytics.events)
      if (name == 'payment_failed') props?['reason'],
  ];

  Future<void> returnToArul(WidgetTester tester, ProviderContainer c) async {
    await notifierOf(c).pollNowOnResume();
    await tester.pump();
  }

  // Past the 10-minute fallback window every watch stops by itself.
  Future<void> drain(WidgetTester tester) =>
      tester.pump(const Duration(minutes: 20));

  testWidgets(
    'resubscribe: a quick "open again", then a second back-out, is resumable '
    'again — never a spinner that ends in confirmation_late',
    (tester) async {
      final c = await build(tester);
      unawaited(notifierOf(c).startTrial(targetApp: _phonePe));
      await tester.pump(const Duration(milliseconds: 10));
      expect(stateOf(c), isA<PurchaseProcessing>());

      await returnToArul(tester, c);
      final first = stateOf(c);
      expect(first, isA<PurchaseResumable>());

      // Tapped inside a second, while the first poll still sleeps out its 4 s delay.
      unawaited(notifierOf(c).resumeIntent());
      await tester.pump(const Duration(milliseconds: 500));
      expect(stateOf(c), isA<PurchaseProcessing>());
      expect(launches, hasLength(2));

      // Past the first poll's wake-up, before the resumed poll's own.
      await tester.pump(const Duration(milliseconds: 3700));
      expect(stateOf(c), isA<PurchaseProcessing>());

      await returnToArul(tester, c);
      final second = stateOf(c);
      expect(second, isA<PurchaseResumable>());
      expect((second as PurchaseResumable).merchantOrderId, 'DKS_ORDER_1');
      expect(second.expiresAt, (first as PurchaseResumable).expiresAt);
      expect(api.initiates, 1);
      expect(api.abandons, 0);

      // Well past the resumed poll's ~2-minute budget: still the button, never a failure.
      await tester.pump(const Duration(minutes: 3));
      expect(stateOf(c), isA<PurchaseResumable>());
      expect(failureReasons(), isEmpty);
      await drain(tester);
    },
  );

  testWidgets('a second quick resume survives the first resume\'s poll', (
    tester,
  ) async {
    final c = await build(tester);
    unawaited(notifierOf(c).startTrial(targetApp: _phonePe));
    await tester.pump(const Duration(milliseconds: 10));
    await returnToArul(tester, c);
    // The launch's own poll is long gone before this resume.
    await tester.pump(const Duration(seconds: 5));

    unawaited(notifierOf(c).resumeIntent());
    await tester.pump(const Duration(milliseconds: 10));
    await returnToArul(tester, c);
    expect(stateOf(c), isA<PurchaseResumable>());

    unawaited(notifierOf(c).resumeIntent());
    await tester.pump(const Duration(milliseconds: 10));
    // Past the first resume's wake-up.
    await tester.pump(const Duration(seconds: 4));
    await returnToArul(tester, c);

    expect(stateOf(c), isA<PurchaseResumable>());
    expect(launches, hasLength(3));
    expect(api.initiates, 1);
    await drain(tester);
  });

  testWidgets('a quick switch to another app is resumable on the NEW order', (
    tester,
  ) async {
    final c = await build(tester);
    unawaited(
      notifierOf(c).startTrial(targetApp: _phonePe, trialEligible: true),
    );
    await tester.pump(const Duration(milliseconds: 10));
    await returnToArul(tester, c);
    expect(stateOf(c), isA<PurchaseResumable>());

    unawaited(notifierOf(c).switchApp(_gpay, trialEligible: true));
    await tester.pump(const Duration(milliseconds: 50));
    expect(stateOf(c), isA<PurchaseProcessing>());
    expect(api.initiates, 2);

    // Past the first order's poll waking up.
    await tester.pump(const Duration(seconds: 4));
    await returnToArul(tester, c);

    final state = stateOf(c);
    expect(state, isA<PurchaseResumable>());
    expect((state as PurchaseResumable).merchantOrderId, 'DKS_ORDER_2');
    expect(state.targetApp, _gpay);
    expect(failureReasons(), ['intent_app_switched']);
    await drain(tester);
  });

  testWidgets('a quick ₹99 retry that comes back open is released, not left '
      'spinning', (tester) async {
    final c = await build(tester);
    Future<void> startOffer() =>
        notifierOf(c).startTrial(targetApp: _phonePe, offer: kCancelOffer);

    unawaited(startOffer());
    await tester.pump(const Duration(milliseconds: 10));
    await returnToArul(tester, c);
    expect(stateOf(c), isA<PurchaseError>());
    // What the member view does with an offer failure before its retry sheet.
    notifierOf(c).reset();

    unawaited(startOffer());
    await tester.pump(const Duration(milliseconds: 10));
    expect(stateOf(c), isA<PurchaseProcessing>());
    // Past the first attempt's poll waking up.
    await tester.pump(const Duration(seconds: 4));
    await returnToArul(tester, c);

    final state = stateOf(c);
    expect(state, isA<PurchaseError>());
    expect((state as PurchaseError).offer, isTrue);
    expect(api.abandons, 2);
    expect(failureReasons(), ['offer_abandoned', 'offer_abandoned']);
    await drain(tester);
  });

  testWidgets('an SDK checkout started inside an old poll\'s sleep is never '
      'taken for that poll\'s order', (tester) async {
    final c = await build(tester);
    unawaited(
      notifierOf(c).startTrial(targetApp: _phonePe, trialEligible: true),
    );
    await tester.pump(const Duration(milliseconds: 10));
    // PhonePe already killed the order: the first poll is silenced but still asleep.
    api.status = 'expired';
    await returnToArul(tester, c);
    expect(stateOf(c), isA<PurchaseError>());
    notifierOf(c).reset();

    api.status = 'pending';
    unawaited(notifierOf(c).startTrial(trialEligible: true));
    await tester.pump(const Duration(milliseconds: 10));
    expect(stateOf(c), isA<PurchaseProcessing>());

    // A lifecycle resume while the SDK's own page is still up.
    await returnToArul(tester, c);
    expect(stateOf(c), isA<PurchaseProcessing>());
    expect(api.abandons, 0);
    expect(failureReasons(), ['expired']);

    api.status = 'trialing';
    sdkResult.complete({'status': 'SUCCESS'});
    await tester.pump(const Duration(seconds: 2));
    expect(stateOf(c), isA<PurchaseSuccess>());
    await drain(tester);
  });

  testWidgets('a status answer for the order a switch replaced changes '
      'nothing', (tester) async {
    final c = await build(tester);
    unawaited(
      notifierOf(c).startTrial(targetApp: _phonePe, trialEligible: true),
    );
    await tester.pump(const Duration(milliseconds: 10));
    await returnToArul(tester, c);
    expect(stateOf(c), isA<PurchaseResumable>());

    // The resumable watch's first tick goes out on a slow link and stays there.
    final stale = Completer<Map<String, dynamic>>();
    api.heldStatus = stale;
    await tester.pump(const Duration(seconds: 3));

    unawaited(notifierOf(c).switchApp(_gpay, trialEligible: true));
    await tester.pump(const Duration(milliseconds: 50));
    expect(stateOf(c), isA<PurchaseProcessing>());

    // PhonePe's verdict on the FIRST order lands while the person is inside GPay with the second.
    stale.complete({'status': 'expired'});
    await tester.pump(const Duration(milliseconds: 10));

    expect(stateOf(c), isA<PurchaseProcessing>());
    expect(failureReasons(), ['intent_app_switched']);
    await returnToArul(tester, c);
    final state = stateOf(c);
    expect(state, isA<PurchaseResumable>());
    expect((state as PurchaseResumable).merchantOrderId, 'DKS_ORDER_2');
    await drain(tester);
  });

  testWidgets('past the deadline, resume and switch leave the deadline\'s '
      'abandon to finish', (tester) async {
    final c = await build(tester);
    unawaited(
      notifierOf(c).startTrial(targetApp: _phonePe, trialEligible: true),
    );
    await tester.pump(const Duration(milliseconds: 10));
    await returnToArul(tester, c);

    // The watch reaches the 10-minute fallback deadline; its abandon is still on the wire.
    final abandon = Completer<void>();
    api.heldAbandon = abandon;
    await tester.pump(const Duration(minutes: 11));
    expect(stateOf(c), isA<PurchaseResumable>());
    expect(api.abandons, 1);

    unawaited(notifierOf(c).resumeIntent());
    await tester.pump(const Duration(milliseconds: 10));
    unawaited(notifierOf(c).switchApp(_gpay, trialEligible: true));
    await tester.pump(const Duration(milliseconds: 10));
    expect(launches, hasLength(1), reason: 'a dead link is never re-opened');
    expect(api.initiates, 1);

    abandon.complete();
    await tester.pump(const Duration(milliseconds: 10));
    expect(stateOf(c), isA<PurchaseIdle>());
    expect(api.abandons, 1);
    expect(failureReasons(), ['intent_resume_expired']);
    await drain(tester);
  });

  testWidgets(
    'resubscribe: a claim the Worker released reads as dead on return, never '
    'a live "open again"',
    (tester) async {
      final c = await build(tester);
      unawaited(notifierOf(c).startTrial(targetApp: _phonePe));
      await tester.pump(const Duration(milliseconds: 10));
      await returnToArul(tester, c);
      expect(stateOf(c), isA<PurchaseResumable>());

      // PhonePe failed the order and the Worker handed the paid period back.
      api.status = 'cancelled';
      await returnToArul(tester, c);
      expect(stateOf(c), isA<PurchaseIdle>());
      expect(failureReasons(), ['claim_released']);
      await drain(tester);
    },
  );

  testWidgets(
    'resubscribe: a released claim mid-poll is the intent failure, not '
    'activateFailed',
    (tester) async {
      final c = await build(tester);
      api.status = 'cancelled';
      unawaited(notifierOf(c).startTrial(targetApp: _phonePe));
      await tester.pump(const Duration(seconds: 5));

      final state = stateOf(c);
      expect(state, isA<PurchaseError>());
      expect((state as PurchaseError).kind, PurchaseErrorKind.intentFailed);
      expect(failureReasons(), ['claim_released']);
      await drain(tester);
    },
  );
}
