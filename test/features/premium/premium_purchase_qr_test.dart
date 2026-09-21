// A phone with no mandate-capable UPI app used to get a dead CTA: 13.4% of everyone who tapped
// Subscribe (811 of 6,035 users, 3–10 Sep) reached the SDK path, and the hosted page it led to
// completed 4 mandates in 790. The QR is the route that does not need an app on THIS phone — the
// `upi://mandate` PhonePe returns carries no app binding, so a second phone can scan and approve it.
//
// What this file pins is everything that could quietly cost money on that path:
//   • nothing is ever LAUNCHED — there is no app here to launch, and a launch would fail silently;
//   • `/payments/initiate` — one per decision, and NEVER a second one while a code is on screen,
//     because the order it would revoke is the one somebody may be scanning;
//   • the deadline is the LINK's, and reaching it is silent: nothing was approved, so the refund
//     line would be a lie and the CTA simply sells again;
//   • a Worker that fell back to the SDK page answers a QR request with nothing usable, and that
//     must end the attempt rather than open a page this phone cannot finish.
//
// Time is faked through `PremiumPurchase.clock` for the same reason as the resume tests: the
// deadline is a wall-clock fact, because Android freezes a backgrounded process and its timers.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:arul/core/analytics/analytics_provider.dart';
import 'package:arul/core/analytics/analytics_service.dart';
import 'package:arul/core/api/api_client.dart';
import 'package:arul/core/providers/shared_preferences_provider.dart';
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

  @override
  void register(String key, Object value) {}
}

/// [intentUrl] null = the Worker fell back to the SDK page, which is what it does inside the SAME
/// request whenever the intent setup fails. A QR attempt has to recognise that answer as unusable.
class _FakeApi extends ApiClient {
  _FakeApi(this.statuses, {this.intentUrl});

  final List<String> statuses;
  final String? intentUrl;

  final initiateBodies = <Map<String, dynamic>?>[];
  int statusCalls = 0;
  int abandons = 0;

  int get initiates => initiateBodies.length;

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Map<String, dynamic>? body,
    bool requiresAuth = true,
  }) async {
    switch (path) {
      case '/payments/initiate':
        initiateBodies.add(body);
        return {
          'merchantOrderId': 'DKS_ORDER_1',
          if (intentUrl != null) 'intentUrl': intentUrl,
          // What the SDK-page fallback answers with. A QR attempt must ignore every one of these.
          if (intentUrl == null) ...{
            'orderId': 'OMO1',
            'token': 'tok',
            'merchantId': 'M1',
            'environment': 'PRODUCTION',
          },
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

/// The package the QR path names to satisfy PhonePe's mandatory `paymentMode.targetApp`.
const _formalityPackage = 'com.phonepe.app';

/// PhonePe writes the deadline into the link itself — ISO-8601, an UNENCODED `+05:30` offset and
/// nine fraction digits. Production links carry roughly five minutes.
String _urlExpiringAt(DateTime at) {
  final t = at.toUtc().add(const Duration(hours: 5, minutes: 30));
  String two(int v) => v.toString().padLeft(2, '0');
  final nanos = (t.millisecond * 1000 + t.microsecond).toString().padLeft(
    6,
    '0',
  );
  final iso =
      '${t.year}-${two(t.month)}-${two(t.day)}T'
      '${two(t.hour)}:${two(t.minute)}:${two(t.second)}.${nanos}000+05:30';
  return 'upi://mandate?pa=arul@ybl&tr=DKS_ORDER_1&QRts=$iso&QRexpire=$iso&am=2';
}

void main() {
  late _RecordingAnalytics analytics;
  late List<MethodCall> channelCalls;

  Future<ProviderContainer> build(WidgetTester tester, _FakeApi api) async {
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    analytics = _RecordingAnalytics();
    channelCalls = [];
    PremiumPurchase.clock = () => tester.binding.clock.now();
    addTearDown(() => PremiumPurchase.clock = DateTime.now);

    // Recorded, never answered usefully: the whole claim of this path is that nothing is launched.
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      _upiChannel,
      (call) async {
        channelCalls.add(call);
        return call.method == 'launch' ? true : null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        _upiChannel,
        null,
      ),
    );

    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
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
    // The paywall is open throughout — the sheet is a screen, and the notifier is autoDispose.
    final sub = container.listen(premiumPurchaseProvider, (_, _) {});
    addTearDown(sub.close);
    await container.read(appConfigProvider.future);
    return container;
  }

  List<Map<String, Object?>?> eventsNamed(String name) =>
      analytics.events.where((e) => e.$1 == name).map((e) => e.$2).toList();

  Future<void> showQr(WidgetTester tester, ProviderContainer container) async {
    unawaited(
      container
          .read(premiumPurchaseProvider.notifier)
          .startTrial(
            targetApp: _formalityPackage,
            trialEligible: true,
            asQr: true,
          ),
    );
    await tester.pump(const Duration(milliseconds: 10));
  }

  /// Past any window, so no test leaves a watch running.
  Future<void> drain(WidgetTester tester) =>
      tester.pump(const Duration(minutes: 20));

  group('showing the code', () {
    testWidgets('the link goes on screen VERBATIM and nothing is launched', (
      tester,
    ) async {
      final url = _urlExpiringAt(
        tester.binding.clock.now().add(const Duration(minutes: 5)),
      );
      final api = _FakeApi(const ['pending'], intentUrl: url);
      final container = await build(tester, api);

      await showQr(tester, container);

      final state = container.read(premiumPurchaseProvider);
      expect(state, isA<PurchaseScannable>());
      // Rebuilding the payload from its parts is how a QR stops matching the order behind it.
      expect((state as PurchaseScannable).intentUrl, url);
      expect(state.merchantOrderId, 'DKS_ORDER_1');
      // There is no app on this phone to launch. A launch call here would fail silently and leave
      // the user staring at a code nobody is watching.
      expect(channelCalls.where((c) => c.method == 'launch'), isEmpty);

      await drain(tester);
    });

    testWidgets('the deadline is the LINK\'s own QRexpire, never a guess', (
      tester,
    ) async {
      final expiry = tester.binding.clock.now().add(const Duration(minutes: 5));
      final api = _FakeApi(const [
        'pending',
      ], intentUrl: _urlExpiringAt(expiry));
      final container = await build(tester, api);

      await showQr(tester, container);

      final state =
          container.read(premiumPurchaseProvider) as PurchaseScannable;
      // A client window SHORTER than PhonePe's would say "expired" while the code was still live,
      // and a late scan would then set up a mandate the UI had already given up on.
      expect(
        state.expiresAt.difference(expiry).abs(),
        lessThan(const Duration(seconds: 2)),
      );

      await drain(tester);
    });

    testWidgets('the Worker is told this is a QR, and the package rides along '
        'because PhonePe requires one', (tester) async {
      final api = _FakeApi(
        const ['pending'],
        intentUrl: _urlExpiringAt(
          tester.binding.clock.now().add(const Duration(minutes: 5)),
        ),
      );
      final container = await build(tester, api);

      await showQr(tester, container);

      // Without `mode` the Worker files the order under com.phonepe.app, which would put mandates
      // PhonePe never saw into the column that answers "which app completes one".
      expect(api.initiateBodies.single, {
        'plan': 'monthly',
        'targetApp': _formalityPackage,
        'mode': 'qr',
      });

      await drain(tester);
    });

    testWidgets('checkout_started says upi_qr and names NO app', (
      tester,
    ) async {
      final api = _FakeApi(
        const ['pending'],
        intentUrl: _urlExpiringAt(
          tester.binding.clock.now().add(const Duration(minutes: 5)),
        ),
      );
      final container = await build(tester, api);

      await showQr(tester, container);

      final started = eventsNamed('checkout_started').single!;
      expect(started['method'], 'upi_qr');
      // The package was never launched and the approval may happen on a different phone —
      // reporting it would corrupt the breakdown that ranks UPI apps by completions.
      expect(started.containsKey('target_app'), isFalse);

      await drain(tester);
    });
  });

  group('while the code is live', () {
    testWidgets('a second tap does NOT initiate — it would revoke the order '
        'somebody is scanning', (tester) async {
      final api = _FakeApi(
        const ['pending'],
        intentUrl: _urlExpiringAt(
          tester.binding.clock.now().add(const Duration(minutes: 5)),
        ),
      );
      final container = await build(tester, api);

      await showQr(tester, container);
      await showQr(tester, container);

      expect(api.initiates, 1);
      expect(container.read(premiumPurchaseProvider), isA<PurchaseScannable>());
      expect(eventsNamed('checkout_started'), hasLength(1));

      await drain(tester);
    });

    testWidgets('an approval on the other phone settles by itself', (
      tester,
    ) async {
      final api = _FakeApi(
        const ['pending', 'pending', 'trialing'],
        intentUrl: _urlExpiringAt(
          tester.binding.clock.now().add(const Duration(minutes: 5)),
        ),
      );
      final container = await build(tester, api);

      await showQr(tester, container);
      // Nobody returns to Arul on this path, so the watch is the only thing that can notice.
      await tester.pump(const Duration(seconds: 30));

      expect(container.read(premiumPurchaseProvider), isA<PurchaseSuccess>());
      expect(eventsNamed('trial_started'), hasLength(1));
      expect(api.abandons, 0);

      await drain(tester);
    });

    testWidgets(
      'the Check button asks sooner and cannot settle anything else',
      (tester) async {
        final api = _FakeApi(
          const ['trialing'],
          intentUrl: _urlExpiringAt(
            tester.binding.clock.now().add(const Duration(minutes: 5)),
          ),
        );
        final container = await build(tester, api);

        await showQr(tester, container);
        unawaited(
          container.read(premiumPurchaseProvider.notifier).checkQrStatus(),
        );
        await tester.pump(const Duration(milliseconds: 50));

        expect(container.read(premiumPurchaseProvider), isA<PurchaseSuccess>());
        expect(api.statusCalls, 1);

        await drain(tester);
      },
    );
  });

  group('the deadline', () {
    testWidgets('passing is SILENT — idle, counted, and no failure copy', (
      tester,
    ) async {
      final api = _FakeApi(
        const ['pending'],
        intentUrl: _urlExpiringAt(
          tester.binding.clock.now().add(const Duration(minutes: 5)),
        ),
      );
      final container = await build(tester, api);

      await showQr(tester, container);
      await tester.pump(const Duration(minutes: 6));

      // Nothing was ever approved, so "any amount deducted will be refunded" would be false.
      // Idle is the one state startTrial accepts, so the CTA reads as the offer again.
      expect(container.read(premiumPurchaseProvider), isA<PurchaseIdle>());
      expect(eventsNamed('payment_failed').single!['reason'], 'qr_expired');
      // One abandon releases the claim; a second initiate here would be a mandate nobody asked for.
      expect(api.abandons, 1);
      expect(api.initiates, 1);

      await drain(tester);
    });
  });

  group('when the Worker could not make a QR', () {
    testWidgets('an SDK-page answer ends the attempt instead of opening a page '
        'this phone cannot finish', (tester) async {
      // The Worker falls back to the SDK page inside the same request on ANY intent failure. That
      // page needs a UPI app on THIS phone — the one thing we already know is missing.
      final api = _FakeApi(const ['pending']);
      final container = await build(tester, api);

      await showQr(tester, container);
      await tester.pump(const Duration(milliseconds: 100));

      expect(container.read(premiumPurchaseProvider), isA<PurchaseError>());
      expect(eventsNamed('payment_failed').single!['reason'], 'qr_unavailable');
      // The claim is released, so the next tap starts clean rather than bouncing off 409.
      expect(api.abandons, 1);
      // And no SDK transaction was ever started.
      expect(channelCalls.where((c) => c.method == 'launch'), isEmpty);

      await drain(tester);
    });
  });
}
