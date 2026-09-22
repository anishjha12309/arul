// A checkout the person has already committed to must survive the links this audience is on.
//
// About 6 in 100 checkouts ended as `unexpected_error` — "Something went wrong" — and every DNS miss
// and 12 s timeout on `POST /payments/initiate` was inside that number, because the http layer throws
// its own types and never an `ApiException`. None of them was retried, and none was told apart from
// a genuine defect. So: a dead LINK is retried under the spinner, then named (`network_error`, with a
// line the person can act on); a server ANSWER is never retried; whatever is left is a real defect.

import 'dart:async';
import 'dart:io';
import 'dart:ui' show Locale;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:arul/app/l10n/app_localizations.dart';
import 'package:arul/core/analytics/analytics_provider.dart';
import 'package:arul/core/analytics/analytics_service.dart';
import 'package:arul/core/api/api_client.dart';
import 'package:arul/core/providers/shared_preferences_provider.dart';
import 'package:arul/data/models/app_config_model.dart';
import 'package:arul/data/repositories/repository_providers.dart';
import 'package:arul/features/auth/providers/auth_providers.dart';
import 'package:arul/features/premium/presentation/premium_screen.dart';
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

/// `/payments/initiate` throws [initiateFailures] in order, then answers.
class _FlakyApi extends ApiClient {
  _FlakyApi(this.initiateFailures);

  final List<Object> initiateFailures;
  int initiates = 0;

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Map<String, dynamic>? body,
    bool requiresAuth = true,
  }) async {
    switch (path) {
      case '/payments/initiate':
        final i = initiates++;
        if (i < initiateFailures.length) throw initiateFailures[i];
        return {
          'merchantOrderId': 'DKS_ORDER_1',
          'intentUrl': 'upi://mandate?tr=DKS_ORDER_1&am=2',
        };
      case '/payments/status':
        return {'status': 'pending'};
      case '/payments/abandon':
        return {'settled': false};
    }
    throw StateError('unexpected POST $path');
  }
}

/// Every initiate hangs for [hang] and then dies as ApiClient's timeout does — except the posts
/// numbered in [conflictOn] (1-based), which answer 409 at once: the repeat of a request that landed.
class _SlowDeadApi extends ApiClient {
  _SlowDeadApi(this.hang, {this.conflictOn = const {}});

  final Duration hang;
  final Set<int> conflictOn;
  int initiates = 0;

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Map<String, dynamic>? body,
    bool requiresAuth = true,
  }) async {
    if (path != '/payments/initiate') return {'settled': false};
    final n = ++initiates;
    if (conflictOn.contains(n)) {
      throw const ApiException(
        status: 409,
        code: 'setup_in_progress',
        message: 'A payment setup is already in progress',
      );
    }
    await Future<void>.delayed(hang);
    throw http.ClientException('Request timed out after 12s');
  }
}

const _upiChannel = MethodChannel('com.hsrutility.arul/upi_intent');
const _phonePe = 'com.phonepe.app';

void main() {
  late _RecordingAnalytics analytics;
  late List<Object?> launches;

  Future<ProviderContainer> build(WidgetTester tester, ApiClient api) async {
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    analytics = _RecordingAnalytics();
    launches = [];
    PremiumPurchase.clock = () => tester.binding.clock.now();
    addTearDown(() => PremiumPurchase.clock = DateTime.now);

    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      _upiChannel,
      (call) async {
        if (call.method != 'launch') return null;
        launches.add(call.arguments);
        return true;
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
    final sub = container.listen(premiumPurchaseProvider, (_, _) {});
    addTearDown(sub.close);
    await container.read(appConfigProvider.future);
    return container;
  }

  List<Map<String, Object?>?> eventsNamed(String name) =>
      analytics.events.where((e) => e.$1 == name).map((e) => e.$2).toList();

  Future<void> tapCta(WidgetTester tester, ProviderContainer container) async {
    unawaited(
      container
          .read(premiumPurchaseProvider.notifier)
          .startTrial(targetApp: _phonePe, trialEligible: true),
    );
    // Past every backoff the retry policy can spend, short of the first status poll mattering.
    await tester.pump(PremiumPurchase.initiateBackoff * 4);
  }

  Future<void> drain(WidgetTester tester) =>
      tester.pump(const Duration(minutes: 20));

  testWidgets('a link that blips once still reaches the UPI app', (
    tester,
  ) async {
    final api = _FlakyApi([const SocketException('Failed host lookup')]);
    final container = await build(tester, api);
    await tapCta(tester, container);

    expect(api.initiates, 2);
    expect(launches, hasLength(1));
    expect(eventsNamed('payment_failed'), isEmpty);
    expect(
      eventsNamed('checkout_started'),
      hasLength(1),
      reason: 'a retry is the same decision — ★ fires once',
    );
    expect(container.read(premiumPurchaseProvider), isA<PurchaseProcessing>());
    await drain(tester);
  });

  testWidgets('a timeout is a link failure too', (tester) async {
    final api = _FlakyApi([
      http.ClientException('Request timed out after 12s'),
      TimeoutException('poll'),
    ]);
    final container = await build(tester, api);
    await tapCta(tester, container);

    expect(api.initiates, 3);
    expect(launches, hasLength(1));
    expect(eventsNamed('payment_failed'), isEmpty);
    await drain(tester);
  });

  testWidgets('a dead link is named, never "something went wrong"', (
    tester,
  ) async {
    final api = _FlakyApi(
      List.filled(10, const SocketException('Failed host lookup')),
    );
    final container = await build(tester, api);
    await tapCta(tester, container);

    expect(api.initiates, PremiumPurchase.initiateMaxAttempts);
    expect(launches, isEmpty);
    final state = container.read(premiumPurchaseProvider);
    expect(state, isA<PurchaseError>());
    expect((state as PurchaseError).kind, PurchaseErrorKind.network);
    expect(state.cancelled, isFalse);
    expect(eventsNamed('payment_failed').single?['reason'], 'network_error');
  });

  testWidgets('a server answer is never retried', (tester) async {
    final api = _FlakyApi([
      const ApiException(status: 500, code: 'server_error', message: 'boom'),
    ]);
    final container = await build(tester, api);
    await tapCta(tester, container);

    expect(api.initiates, 1);
    expect(launches, isEmpty);
    // The Worker's English sentence is for the log — on screen it is the localized generic line.
    final state = container.read(premiumPurchaseProvider) as PurchaseError;
    expect(state.kind, PurchaseErrorKind.generic);
    expect(eventsNamed('payment_failed').single?['reason'], 'api_error');
  });

  testWidgets('a second 12 s timeout spends the budget — a third never starts', (
    tester,
  ) async {
    // Timed on the notifier's own clock, which the test owns: two timeouts are 25.5 s, past the
    // 15 s cap, so the attempt count alone (3) must NOT be what stops it.
    final api = _SlowDeadApi(const Duration(seconds: 12));
    final container = await build(tester, api);
    unawaited(
      container
          .read(premiumPurchaseProvider.notifier)
          .startTrial(targetApp: _phonePe, trialEligible: true),
    );
    await tester.pump(const Duration(seconds: 60));

    expect(api.initiates, 2);
    expect(launches, isEmpty);
    expect(eventsNamed('payment_failed').single?['reason'], 'network_error');
  });

  testWidgets('a timeout that landed as a 409 does not buy a fresh budget', (
    tester,
  ) async {
    // First post times out at 12 s but reached the Worker; the retry is refused inside the claim
    // window; the post after that dies again. One budget: nothing may run past that third post.
    final api = _SlowDeadApi(
      const Duration(seconds: 12),
      conflictOn: const {2},
    );
    final container = await build(tester, api);
    unawaited(
      container
          .read(premiumPurchaseProvider.notifier)
          .startTrial(targetApp: _phonePe, trialEligible: true),
    );
    await tester.pump(const Duration(seconds: 90));

    expect(api.initiates, 3);
    expect(eventsNamed('payment_failed').single?['reason'], 'network_error');
  });

  testWidgets('a genuine defect keeps its own code', (tester) async {
    final api = _FlakyApi([StateError('not a link problem')]);
    final container = await build(tester, api);
    await tapCta(tester, container);

    expect(api.initiates, 1);
    final state = container.read(premiumPurchaseProvider) as PurchaseError;
    expect(state.kind, PurchaseErrorKind.generic);
    expect(eventsNamed('payment_failed').single?['reason'], 'unexpected_error');
  });

  // ─── The line the person reads ────────────────────────────────────────────

  test('every failure kind has a line in every language', () {
    final english = lookupAppLocalizations(const Locale('en'));
    for (final locale in AppLocalizations.supportedLocales) {
      final l10n = lookupAppLocalizations(locale);
      for (final kind in PurchaseErrorKind.values) {
        final text = purchaseErrorText(l10n, kind);
        expect(text.trim(), isNotEmpty, reason: '$locale/$kind');
        if (locale.languageCode != 'en') {
          expect(
            text,
            isNot(purchaseErrorText(english, kind)),
            reason: '$locale/$kind fell back to English',
          );
        }
      }
    }
  });
}
