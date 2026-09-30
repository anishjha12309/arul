// The ₹99 cancel-save offer, from "Cancel it" to its outcome.
//
// The offer sits between a subscriber's decision to cancel and the cancel itself, so every path out
// of it must land on exactly one of: the switch, the cancel as asked, or nothing changed. And the
// switch is a subscriber keeping their plan — it may never count as a trial or a conversion.

import 'dart:async';

import 'package:arul/app/l10n/app_localizations.dart';
import 'package:arul/app/theme/theme.dart';
import 'package:arul/core/analytics/analytics_provider.dart';
import 'package:arul/core/analytics/analytics_service.dart';
import 'package:arul/core/api/api_client.dart';
import 'package:arul/core/providers/shared_preferences_provider.dart';
import 'package:arul/core/upi/upi_apps.dart';
import 'package:arul/data/models/app_config_model.dart';
import 'package:arul/data/models/subscription_model.dart';
import 'package:arul/data/repositories/repository_providers.dart';
import 'package:arul/features/auth/providers/auth_providers.dart';
import 'package:arul/features/premium/domain/entitlement.dart';
import 'package:arul/features/premium/domain/trial_nudge.dart';
import 'package:arul/features/premium/presentation/premium_screen.dart';
import 'package:arul/features/premium/providers/entitlement_provider.dart';
import 'package:arul/features/premium/providers/premium_purchase_provider.dart';
import 'package:arul/features/premium/providers/trial_conversion_catch_up.dart';
import 'package:arul/theme/arul_tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// `Override` is only exported from the misc entry point in Riverpod 3.
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
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

Map<String, dynamic> _statusRow(String status, int pricePaise) => {
  'status': status,
  'subscription': {
    'status': status,
    'merchant_order_id': 'DKS_OFFER_1',
    'price_paise': pricePaise,
    'trial_end': DateTime.now()
        .add(const Duration(hours: 20))
        .toIso8601String(),
  },
};

/// Records every POST; `/payments/initiate` answers [initiate]'s result, or throws it.
class _FakeApi extends ApiClient {
  final posts = <(String, Map<String, dynamic>?)>[];

  Object initiate = {
    'merchantOrderId': 'DKS_OFFER_1',
    'intentUrl': 'upi://mandate?tr=DKS_OFFER_1&am=2',
    'trialEligible': false,
    'amountPaise': 200,
    'offer': 'cancel_99',
    'pricePaise': 9900,
  };

  Map<String, dynamic> status = _statusRow('pending', 19900);

  List<Map<String, dynamic>?> bodiesOf(String path) => [
    for (final (p, body) in posts)
      if (p == path) body,
  ];

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Map<String, dynamic>? body,
    bool requiresAuth = true,
    bool withToken = true,
    Duration? timeout,
  }) async {
    posts.add((path, body));
    switch (path) {
      case '/payments/initiate':
        final answer = initiate;
        if (answer is Map<String, dynamic>) return answer;
        throw answer;
      case '/payments/status':
        return status;
      case '/payments/abandon':
        return {'settled': false};
    }
    return {};
  }
}

const _upiChannel = MethodChannel('com.hsrutility.arul/upi_intent');
const _phonePe = UpiApp(packageName: 'com.phonepe.app', label: 'PhonePe');

void main() {
  late _RecordingAnalytics analytics;
  late _FakeApi api;
  late SharedPreferences prefs;
  late bool launchResult;

  setUp(() {
    analytics = _RecordingAnalytics();
    api = _FakeApi();
    launchResult = true;
  });

  List<Map<String, Object?>?> eventsNamed(String name) =>
      analytics.events.where((e) => e.$1 == name).map((e) => e.$2).toList();

  void mockChannels(WidgetTester tester) {
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      _upiChannel,
      (call) async => call.method == 'launch' ? launchResult : null,
    );
    for (final name in const ['arul/feed_video', 'arul/feed_video_events']) {
      messenger.setMockMethodCallHandler(
        MethodChannel(name),
        (_) async => null,
      );
    }
    addTearDown(() {
      messenger.setMockMethodCallHandler(_upiChannel, null);
      for (final name in const ['arul/feed_video', 'arul/feed_video_events']) {
        messenger.setMockMethodCallHandler(MethodChannel(name), null);
      }
    });
  }

  List<Override> baseOverrides() => [
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
  ];

  group('the member view', () {
    Future<void> openPlanHome(
      WidgetTester tester, {
      required bool eligible,
      List<UpiApp> apps = const [_phonePe],
    }) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues(const {});
      prefs = await SharedPreferences.getInstance();
      PremiumPurchase.clock = () => tester.binding.clock.now();
      addTearDown(() => PremiumPurchase.clock = DateTime.now);
      mockChannels(tester);

      final sub = SubscriptionModel(
        id: 'sub_1',
        userId: 'u_1',
        status: SubscriptionStatus.active,
        merchantOrderId: 'DKS_ORIGINAL',
        currentPeriodEnd: DateTime(2026, 10, 13, 12),
        cancelOfferEligible: eligible,
      );
      final router = GoRouter(
        initialLocation: '/premium',
        routes: [
          GoRoute(
            path: '/premium',
            builder: (_, _) => const PremiumScreen(source: 'settings'),
          ),
          GoRoute(path: '/browse', builder: (_, _) => const SizedBox()),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ...baseOverrides(),
            entitlementDetailProvider.overrideWith(
              (ref) async => Entitlement(isPremium: true, subscription: sub),
            ),
            installedUpiAppsProvider.overrideWith(
              (ref) async => UpiScan(apps: apps, otherPackages: const []),
            ),
          ],
          child: MaterialApp.router(
            theme: ArulTheme.light(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            routerConfig: router,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<void> confirmCancel(WidgetTester tester) async {
      final button = find.byKey(const ValueKey('member-cancel-button'));
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel it'));
      await tester.pumpAndSettle();
    }

    /// Past the UPI app's launch, the sheet's exit and the first status poll — inside the toast's 3 s.
    Future<void> settle(WidgetTester tester, {int seconds = 5}) async {
      for (var i = 0; i < seconds * 2; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
    }

    Future<void> acceptWithPhonePe(WidgetTester tester) async {
      await tester.tap(find.text('Get discount'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('PhonePe'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
    }

    testWidgets('shows the member the price their row pays', (tester) async {
      await openPlanHome(tester, eligible: false);
      expect(find.text('₹199 / month'), findsOneWidget);
    });

    testWidgets(
      'eligible: "Cancel it" opens the offer, and nothing is cancelled yet',
      (tester) async {
        await openPlanHome(tester, eligible: true);
        await confirmCancel(tester);

        expect(find.text('50% OFF'), findsOneWidget);
        expect(find.text('Get discount'), findsOneWidget);
        expect(
          find.text(
            // The date is held together with no-break spaces.
            'Not now cancels your subscription. You keep premium until '
            '13 Oct 2026.',
          ),
          findsOneWidget,
        );
        expect(api.bodiesOf('/payments/cancel'), isEmpty);
        expect(eventsNamed('cancel_offer_shown'), hasLength(1));
      },
    );

    testWidgets(
      'the confirm dialog wears the member card, its date on one line',
      (tester) async {
        await openPlanHome(tester, eligible: false);
        final button = find.byKey(const ValueKey('member-cancel-button'));
        await tester.ensureVisible(button);
        await tester.tap(button);
        await tester.pumpAndSettle();

        expect(
          find.text(
            'Your premium access stays active until 13 Oct 2026. '
            "After that you won't be charged again.",
          ),
          findsOneWidget,
        );
        final card = find.ancestor(
          of: find.text('Cancel subscription?'),
          matching: find.byWidgetPredicate(
            (w) =>
                w is DecoratedBox &&
                (w.decoration as BoxDecoration?)?.gradient ==
                    ArulTokens.paywallPanelFill,
          ),
        );
        expect(card, findsOneWidget);
      },
    );

    testWidgets('ineligible: "Cancel it" cancels as before, with no offer', (
      tester,
    ) async {
      await openPlanHome(tester, eligible: false);
      await confirmCancel(tester);

      expect(find.text('Get discount'), findsNothing);
      expect(api.bodiesOf('/payments/cancel'), [null]);
      expect(eventsNamed('cancel_offer_shown'), isEmpty);
      expect(
        find.text(
          'Subscription cancelled. You keep premium until 13 Oct 2026.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('Not now cancels with the offer declined', (tester) async {
      await openPlanHome(tester, eligible: true);
      await confirmCancel(tester);
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();

      expect(api.bodiesOf('/payments/cancel'), [
        {'offer_declined': true},
      ]);
      expect(eventsNamed('cancel_offer_declined'), hasLength(1));
      expect(
        find.text(
          'Subscription cancelled. You keep premium until 13 Oct 2026.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('the scrim declines the offer too', (tester) async {
      await openPlanHome(tester, eligible: true);
      await confirmCancel(tester);
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();

      expect(find.text('Get discount'), findsNothing);
      expect(api.bodiesOf('/payments/cancel'), [
        {'offer_declined': true},
      ]);
    });

    testWidgets(
      'Get discount switches through the UPI app — no trial, no cancel',
      (tester) async {
        await openPlanHome(tester, eligible: true);
        await confirmCancel(tester);
        await acceptWithPhonePe(tester);

        final initiate = api.bodiesOf('/payments/initiate').single!;
        expect(initiate['offer'], 'cancel_99');
        expect(initiate['targetApp'], 'com.phonepe.app');

        api.status = _statusRow('trialing', 9900);
        await settle(tester);

        expect(find.text("You're on ₹99/month."), findsOneWidget);
        expect(find.text('Get discount'), findsNothing);
        expect(api.bodiesOf('/payments/cancel'), isEmpty);
        expect(eventsNamed('cancel_offer_accepted'), hasLength(1));
        expect(eventsNamed('trial_started'), isEmpty);
        final started = eventsNamed('checkout_started').single!;
        expect(started['offer'], 'cancel_99');
        expect(started['price_paise'], '9900');
        expect(started['paywall_source'], 'cancel_offer');
        // A switch books no paid month.
        expect(eventsNamed('subscription_active'), isEmpty);
        // A subscriber's switch never opens this install's trial marker or its reminder.
        expect(prefs.getString(TrialConversionCatchUp.prefsKey), isNull);
        expect(prefs.getInt(TrialNudge.markerKey), isNull);
      },
    );

    testWidgets('a UPI app that cannot open brings the retry sheet', (
      tester,
    ) async {
      launchResult = false;
      await openPlanHome(tester, eligible: true);
      await confirmCancel(tester);
      await acceptWithPhonePe(tester);
      await settle(tester);

      expect(find.text("Didn't go through"), findsOneWidget);
      expect(
        find.text('Could not open your UPI app. Please try again.'),
        findsOneWidget,
      );
      expect(find.text('Try again'), findsOneWidget);
      expect(eventsNamed('cancel_offer_retry_shown'), hasLength(1));
      expect(eventsNamed('payment_failed').single?['offer'], 'cancel_99');
      expect(api.bodiesOf('/payments/abandon'), hasLength(1));
      expect(api.bodiesOf('/payments/cancel'), isEmpty);
    });

    testWidgets(
      'the Worker handing the ₹199 plan back is a failure, not a switch',
      (tester) async {
        await openPlanHome(tester, eligible: true);
        await confirmCancel(tester);
        await acceptWithPhonePe(tester);

        api.status = _statusRow('active', 19900);
        await settle(tester);

        expect(find.text("Didn't go through"), findsOneWidget);
        expect(
          find.text('Payment was not completed. Please try again.'),
          findsOneWidget,
        );
        expect(find.text("You're on ₹99/month."), findsNothing);
      },
    );

    testWidgets('leaving the retry sheet changes nothing and cancels nothing', (
      tester,
    ) async {
      launchResult = false;
      await openPlanHome(tester, eligible: true);
      await confirmCancel(tester);
      await acceptWithPhonePe(tester);
      await settle(tester);
      expect(find.text("Didn't go through"), findsOneWidget);

      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();

      expect(find.text("Didn't go through"), findsNothing);
      expect(
        find.text("Nothing changed. You're still on ₹199/month."),
        findsOneWidget,
      );
      expect(api.bodiesOf('/payments/cancel'), isEmpty);
    });

    testWidgets('the retry sheet can still cancel, spending the offer', (
      tester,
    ) async {
      launchResult = false;
      await openPlanHome(tester, eligible: true);
      await confirmCancel(tester);
      await acceptWithPhonePe(tester);
      await settle(tester);

      await tester.tap(find.byKey(const ValueKey('cancel-offer-retry-cancel')));
      await tester.pumpAndSettle();

      expect(api.bodiesOf('/payments/cancel'), [
        {'offer_declined': true},
      ]);
      expect(eventsNamed('cancel_offer_declined').single?['sheet'], 'retry');
    });

    testWidgets('a withdrawn offer is a toast, never the retry sheet', (
      tester,
    ) async {
      api.initiate = const ApiException(
        status: 409,
        code: 'offer_unavailable',
        message: 'This offer is not available',
      );
      await openPlanHome(tester, eligible: true);
      await confirmCancel(tester);
      await acceptWithPhonePe(tester);
      await settle(tester, seconds: 1);

      expect(find.text("This offer isn't available any more."), findsOneWidget);
      expect(find.text("Didn't go through"), findsNothing);
      expect(api.bodiesOf('/payments/cancel'), isEmpty);
    });

    testWidgets('a phone with no UPI app goes straight to the QR', (
      tester,
    ) async {
      await openPlanHome(tester, eligible: true, apps: const []);
      await confirmCancel(tester);
      await tester.tap(find.text('Get discount'));
      await tester.pump();
      await settle(tester);

      final initiate = api.bodiesOf('/payments/initiate').single!;
      expect(initiate['offer'], 'cancel_99');
      expect(initiate['mode'], 'qr');
      expect(find.text('Scan to subscribe'), findsOneWidget);
      expect(find.text('Get discount'), findsNothing);

      api.status = _statusRow('active', 9900);
      await tester.tap(find.text('I have paid'));
      await settle(tester, seconds: 1);
      expect(find.text("You're on ₹99/month."), findsOneWidget);
    });
  });

  group('the notifier', () {
    Future<ProviderContainer> build(WidgetTester tester) async {
      SharedPreferences.setMockInitialValues(const {});
      prefs = await SharedPreferences.getInstance();
      PremiumPurchase.clock = () => tester.binding.clock.now();
      addTearDown(() => PremiumPurchase.clock = DateTime.now);
      mockChannels(tester);
      final container = ProviderContainer(overrides: baseOverrides());
      addTearDown(container.dispose);
      final sub = container.listen(premiumPurchaseProvider, (_, _) {});
      addTearDown(sub.close);
      await container.read(appConfigProvider.future);
      return container;
    }

    Future<void> startOffer(ProviderContainer container) => container
        .read(premiumPurchaseProvider.notifier)
        .startTrial(
          targetApp: 'com.phonepe.app',
          trialEligible: true,
          offer: 'cancel_99',
        );

    testWidgets('an open order on return is released, never resumable', (
      tester,
    ) async {
      final container = await build(tester);
      unawaited(startOffer(container));
      await tester.pump(const Duration(milliseconds: 50));
      expect(
        container.read(premiumPurchaseProvider),
        isA<PurchaseProcessing>(),
      );

      await container.read(premiumPurchaseProvider.notifier).pollNowOnResume();
      await tester.pump();

      final state = container.read(premiumPurchaseProvider);
      expect(state, isA<PurchaseError>());
      expect((state as PurchaseError).offer, isTrue);
      expect(state.kind, PurchaseErrorKind.notCompleted);
      expect(api.bodiesOf('/payments/abandon'), [
        {'merchantOrderId': 'DKS_OFFER_1'},
      ]);
      // `trialEligible: true` from a careless caller still arms no unfinished-trial marker.
      expect(prefs.getInt(TrialNudge.markerKey), isNull);
      await tester.pump(const Duration(minutes: 5));
    });

    testWidgets(
      'a switch that lands on a trialing row fires no trial_started',
      (tester) async {
        final container = await build(tester);
        api.status = _statusRow('trialing', 9900);
        unawaited(startOffer(container));
        await tester.pump(const Duration(seconds: 5));

        final state = container.read(premiumPurchaseProvider);
        expect(state, isA<PurchaseSuccess>());
        expect((state as PurchaseSuccess).offer, isTrue);
        expect(eventsNamed('trial_started'), isEmpty);
        expect(eventsNamed('subscription_active'), isEmpty);
      },
    );

    testWidgets('the catch-up never reads an offer row as a late trial', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        TrialConversionCatchUp.prefsKey: 'DKS_ORIGINAL',
      });
      prefs = await SharedPreferences.getInstance();
      final catchUp = TrialConversionCatchUp(
        prefs: prefs,
        analytics: analytics,
        monthlyPriceRupees: () => 199,
      );
      final fired = catchUp.reconcile(
        Entitlement(
          isPremium: true,
          subscription: SubscriptionModel(
            id: 'sub_1',
            userId: 'u_1',
            status: SubscriptionStatus.trialing,
            merchantOrderId: 'DKS_OFFER_1',
            trialEnd: DateTime.now().add(const Duration(hours: 20)),
            pricePaise: 9900,
          ),
        ),
      );
      expect(fired, isFalse);
      expect(eventsNamed('trial_started'), isEmpty);
    });

    testWidgets('cancel sends the flag only when the offer was declined', (
      tester,
    ) async {
      final container = await build(tester);
      final notifier = container.read(premiumPurchaseProvider.notifier);
      await notifier.cancel();
      await notifier.cancel(offerDeclined: true);
      expect(api.bodiesOf('/payments/cancel'), [
        null,
        {'offer_declined': true},
      ]);
    });
  });
}
