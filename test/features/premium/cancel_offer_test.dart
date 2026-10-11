// The ₹99 cancel-save offer, from the Cancel tap to its outcome.
//
// The offer comes first and the confirm after it, so every path out of the sheet must land on
// exactly one of: the switch, the confirm, or nothing changed. And the switch is a subscriber
// keeping their plan — it may never count as a trial or a conversion.

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
import 'package:arul/features/premium/presentation/cancel_offer_sheet.dart';
import 'package:arul/features/premium/presentation/member_view.dart';
import 'package:arul/features/premium/presentation/paywall_view.dart';
import 'package:arul/features/premium/presentation/premium_screen.dart';
import 'package:arul/features/premium/presentation/resubscribe_view.dart';
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

import '../../l10n/support/load_real_fonts.dart';

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

  // Holds `/payments/status` open this long: a real reconcile is a round trip, not a microtask.
  Duration? statusDelay;

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
        final delay = statusDelay;
        if (delay != null) await Future<void>.delayed(delay);
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
      cancelOfferClock = () => tester.binding.clock.now();
      addTearDown(() => cancelOfferClock = DateTime.now);
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

    Future<void> tapCancel(WidgetTester tester) async {
      final button = find.byKey(const ValueKey('member-cancel-button'));
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
    }

    Future<void> tapAndSettle(WidgetTester tester, Finder finder) async {
      await tester.tap(finder);
      await tester.pumpAndSettle();
    }

    /// Past the UPI app's launch, the sheet's exit and the first status poll — inside the toast's 3 s.
    Future<void> settle(WidgetTester tester, {int seconds = 5}) async {
      for (var i = 0; i < seconds * 2; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
    }

    Future<void> acceptWithPhonePe(WidgetTester tester) async {
      await tester.tap(find.text('Get 50% discount'));
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
      'eligible: the Cancel tap opens the offer first, and nothing is cancelled',
      (tester) async {
        await openPlanHome(tester, eligible: true);
        await tapCancel(tester);

        expect(find.text('Special offer'), findsOneWidget);
        expect(find.text('Limited time pricing'), findsOneWidget);
        expect(find.text('50% off'), findsOneWidget);
        expect(find.text('₹99/month', findRichText: true), findsOneWidget);
        expect(
          find.text('Monthly payment, same price forever'),
          findsOneWidget,
        );
        expect(
          find.text('Offer ends in 10:00', findRichText: true),
          findsOneWidget,
        );
        expect(find.text('Get 50% discount'), findsOneWidget);
        expect(find.text("I don't want the offer"), findsOneWidget);
        expect(find.text('Cancel subscription?'), findsNothing);
        expect(api.bodiesOf('/payments/cancel'), isEmpty);
        final tapped = eventsNamed('cancel_tapped').single!;
        expect(tapped['offer_eligible'], isTrue);
        expect(tapped['offer'], 'cancel_99');
        expect(tapped['price_paise'], '19900');
        expect(eventsNamed('cancel_offer_shown'), hasLength(1));
      },
    );

    testWidgets('the hold counts down, then disables the discount', (
      tester,
    ) async {
      await openPlanHome(tester, eligible: true);
      await tapCancel(tester);

      await tester.pump(const Duration(seconds: 61));
      expect(
        find.text('Offer ends in 08:59', findRichText: true),
        findsOneWidget,
      );

      for (var i = 0; i < 9; i++) {
        await tester.pump(const Duration(minutes: 1));
      }
      await tester.pumpAndSettle();
      expect(find.text('Offer ended', findRichText: true), findsOneWidget);
      expect(eventsNamed('cancel_offer_expired'), hasLength(1));

      await tester.tap(find.text('Get 50% discount'));
      await tester.pumpAndSettle();
      expect(find.text('PhonePe'), findsNothing);
      expect(api.bodiesOf('/payments/initiate'), isEmpty);
    });

    testWidgets('a screen reader hears the end once, not a tick a second', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await openPlanHome(tester, eligible: true);
      await tapCancel(tester);
      expect(
        tester.getSemantics(find.bySemanticsLabel('Offer ends in 10:00')),
        matchesSemantics(label: 'Offer ends in 10:00', isLiveRegion: false),
      );

      await tester.pump(const Duration(minutes: 11));
      await tester.pumpAndSettle();
      expect(
        tester.getSemantics(find.bySemanticsLabel('Offer ended')),
        matchesSemantics(label: 'Offer ended', isLiveRegion: true),
      );
      semantics.dispose();
    });

    testWidgets('a fresh Cancel tap is a fresh ten minutes', (tester) async {
      await openPlanHome(tester, eligible: true);
      await tapCancel(tester);
      await tester.pump(const Duration(minutes: 11));
      await tester.pumpAndSettle();
      expect(find.text('Offer ended', findRichText: true), findsOneWidget);

      await tapAndSettle(
        tester,
        find.byKey(const ValueKey('cancel-offer-close')),
      );
      await tapAndSettle(tester, find.text('Keep premium'));
      await tapCancel(tester);
      expect(
        find.text('Offer ends in 10:00', findRichText: true),
        findsOneWidget,
      );
    });

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

    testWidgets('ineligible: the confirm comes straight up, with no offer', (
      tester,
    ) async {
      await openPlanHome(tester, eligible: false);
      await tapCancel(tester);
      expect(find.text('Special offer'), findsNothing);
      await tapAndSettle(tester, find.text('Cancel it'));

      expect(api.bodiesOf('/payments/cancel'), [null]);
      expect(eventsNamed('cancel_offer_shown'), isEmpty);
      expect(
        eventsNamed('cancel_tapped').single!.containsKey('offer'),
        isFalse,
      );
      final confirmed = eventsNamed('cancel_confirmed').single!;
      expect(confirmed['after_offer'], isFalse);
      expect(confirmed.containsKey('offer'), isFalse);
      expect(
        find.text(
          'Subscription cancelled. You keep premium until 13 Oct 2026.',
        ),
        findsOneWidget,
      );
    });

    testWidgets(
      "\"I don't want the offer\" opens the confirm, and Cancel it cancels",
      (tester) async {
        await openPlanHome(tester, eligible: true);
        await tapCancel(tester);
        await tapAndSettle(tester, find.text("I don't want the offer"));

        expect(find.text('Special offer'), findsNothing);
        expect(find.text('Cancel subscription?'), findsOneWidget);
        expect(api.bodiesOf('/payments/cancel'), isEmpty);
        await tapAndSettle(tester, find.text('Cancel it'));

        expect(api.bodiesOf('/payments/cancel'), [
          {'offer_declined': true},
        ]);
        expect(eventsNamed('cancel_offer_declined').single?['via'], 'link');
        final confirmed = eventsNamed('cancel_confirmed').single!;
        expect(confirmed['after_offer'], isTrue);
        expect(confirmed['offer'], 'cancel_99');
        expect(
          find.text(
            'Subscription cancelled. You keep premium until 13 Oct 2026.',
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets('the X, then Keep premium, changes nothing', (tester) async {
      await openPlanHome(tester, eligible: true);
      await tapCancel(tester);
      await tapAndSettle(
        tester,
        find.byKey(const ValueKey('cancel-offer-close')),
      );
      await tapAndSettle(tester, find.text('Keep premium'));

      expect(api.bodiesOf('/payments/cancel'), isEmpty);
      expect(eventsNamed('cancel_offer_declined').single?['via'], 'close');
      expect(eventsNamed('cancel_kept').single?['after_offer'], isTrue);
    });

    testWidgets('the scrim and back open the confirm, never a cancel', (
      tester,
    ) async {
      await openPlanHome(tester, eligible: true);
      await tapCancel(tester);
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();
      expect(find.text('Special offer'), findsNothing);
      expect(find.text('Cancel subscription?'), findsOneWidget);
      await tapAndSettle(tester, find.text('Keep premium'));

      await tapCancel(tester);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Cancel subscription?'), findsOneWidget);

      expect(api.bodiesOf('/payments/cancel'), isEmpty);
      expect(eventsNamed('cancel_offer_declined').map((e) => e?['via']), [
        'dismiss',
        'dismiss',
      ]);
    });

    testWidgets(
      'Get discount switches through the UPI app — no trial, no cancel',
      (tester) async {
        await openPlanHome(tester, eligible: true);
        await tapCancel(tester);
        await acceptWithPhonePe(tester);

        final initiate = api.bodiesOf('/payments/initiate').single!;
        expect(initiate['offer'], 'cancel_99');
        expect(initiate['targetApp'], 'com.phonepe.app');

        api.status = _statusRow('trialing', 9900);
        await settle(tester);

        expect(find.text("You're on ₹99/month."), findsOneWidget);
        expect(find.text('Get 50% discount'), findsNothing);
        expect(find.text('Cancel subscription?'), findsNothing);
        expect(api.bodiesOf('/payments/cancel'), isEmpty);
        expect(eventsNamed('cancel_offer_accepted'), hasLength(1));
        expect(eventsNamed('cancel_offer_switched'), hasLength(1));
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
      await tapCancel(tester);
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
        await tapCancel(tester);
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
      await tapCancel(tester);
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

    testWidgets('the retry sheet can still cancel, through the confirm', (
      tester,
    ) async {
      launchResult = false;
      await openPlanHome(tester, eligible: true);
      await tapCancel(tester);
      await acceptWithPhonePe(tester);
      await settle(tester);

      await tester.tap(find.byKey(const ValueKey('cancel-offer-retry-cancel')));
      await tester.pumpAndSettle();
      expect(api.bodiesOf('/payments/cancel'), isEmpty);
      await tapAndSettle(tester, find.text('Cancel it'));

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
      await tapCancel(tester);
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
      await tapCancel(tester);
      await tester.tap(find.text('Get 50% discount'));
      await tester.pump();
      await settle(tester);

      final initiate = api.bodiesOf('/payments/initiate').single!;
      expect(initiate['offer'], 'cancel_99');
      expect(initiate['mode'], 'qr');
      expect(find.text('Scan to subscribe'), findsOneWidget);
      expect(find.text('Get 50% discount'), findsNothing);

      api.status = _statusRow('active', 9900);
      await tester.tap(find.text('I have paid'));
      await settle(tester, seconds: 1);
      expect(find.text("You're on ₹99/month."), findsOneWidget);
    });
  });

  group('the winback', () {
    Future<void> openResubscribe(
      WidgetTester tester, {
      required bool winback,
    }) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues(const {});
      prefs = await SharedPreferences.getInstance();
      PremiumPurchase.clock = () => tester.binding.clock.now();
      addTearDown(() => PremiumPurchase.clock = DateTime.now);
      cancelOfferClock = () => tester.binding.clock.now();
      addTearDown(() => cancelOfferClock = DateTime.now);
      mockChannels(tester);
      api.initiate = {
        'merchantOrderId': 'DKS_WIN_1',
        'intentUrl': 'upi://mandate?tr=DKS_WIN_1&am=99',
        'trialEligible': false,
        'amountPaise': 9900,
      };

      final sub = SubscriptionModel(
        id: 'sub_1',
        userId: 'u_1',
        status: SubscriptionStatus.cancelled,
        merchantOrderId: 'DKS_ORIGINAL',
        trialEnd: DateTime(2026, 9, 1),
        currentPeriodEnd: DateTime(2026, 10, 13, 12),
        winbackOfferEligible: winback,
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
              (ref) async => const UpiScan(apps: [_phonePe], otherPackages: []),
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

    Future<void> tapResubscribe(WidgetTester tester) async {
      final cta = find.text('Resubscribe');
      await tester.ensureVisible(cta);
      await tester.tap(cta);
      await tester.pumpAndSettle();
    }

    testWidgets('a returning user sees the offer first, and accepting is ₹99 '
        'through the chosen app', (tester) async {
      await openResubscribe(tester, winback: true);
      await tapResubscribe(tester);

      expect(find.text('Special offer'), findsOneWidget);
      expect(api.bodiesOf('/payments/initiate'), isEmpty);
      final shown = eventsNamed('cancel_offer_shown').single!;
      expect(shown['offer'], 'winback_99');
      expect(shown['flow'], 'winback');

      await tester.tap(find.text('Get 50% discount'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      final body = api.bodiesOf('/payments/initiate').single!;
      expect(body['offer'], 'winback_99');
      expect(body['targetApp'], 'com.phonepe.app');
      final started = eventsNamed('checkout_started').single!;
      expect(started['value'], 99.0);
      expect(started['paywall_source'], 'winback_offer');

      // An ordinary sale at ₹99: the paid-month event carries the ₹99 value and the offer.
      api.status = _statusRow('active', 9900);
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      final paid = eventsNamed('subscription_active').single!;
      expect(paid['value'], 99.0);
      expect(paid['offer'], 'winback_99');
      await tester.pumpAndSettle();
    });

    testWidgets("\"I don't want the offer\" continues at the full price", (
      tester,
    ) async {
      await openResubscribe(tester, winback: true);
      await tapResubscribe(tester);
      await tester.tap(find.text("I don't want the offer"));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      final body = api.bodiesOf('/payments/initiate').single!;
      expect(body.containsKey('offer'), isFalse);
      expect(eventsNamed('cancel_offer_declined').single?['via'], 'link');
      // Past the ₹199 attempt's own watch.
      await tester.pump(const Duration(minutes: 20));
    });

    testWidgets('the X leaves them on the screen, with nothing started', (
      tester,
    ) async {
      await openResubscribe(tester, winback: true);
      await tapResubscribe(tester);
      await tester.tap(find.byKey(const ValueKey('cancel-offer-close')));
      await tester.pumpAndSettle();

      expect(find.text('Special offer'), findsNothing);
      expect(find.text('Resubscribe'), findsOneWidget);
      expect(api.bodiesOf('/payments/initiate'), isEmpty);
      expect(eventsNamed('cancel_offer_declined').single?['via'], 'close');
    });

    testWidgets('without the Worker saying so, Resubscribe skips the offer', (
      tester,
    ) async {
      await openResubscribe(tester, winback: false);
      await tester.tap(find.text('Resubscribe'));
      await tester.pumpAndSettle();

      expect(find.text('Special offer'), findsNothing);
      expect(eventsNamed('cancel_offer_shown'), isEmpty);
    });
  });

  // The win-back push opens `/premium?…&offer=winback_99` with `go`, and the ₹99 sheet must already
  // be up: the same sheet a Resubscribe tap opens, never a purchase nobody tapped.
  group('the win-back push', () {
    const landing = '/premium?source=push&offer=winback_99';

    // A lapsed period lands on the paywall, laid out for its own faces; the box glyphs overflow it.
    setUpAll(loadRealFonts);

    SubscriptionModel row({
      SubscriptionStatus status = SubscriptionStatus.cancelled,
      bool winback = true,
      bool trialSpent = true,
    }) => SubscriptionModel(
      id: 'sub_1',
      userId: 'u_1',
      status: status,
      merchantOrderId: 'DKS_ORIGINAL',
      trialEnd: trialSpent ? DateTime(2026, 9, 1) : null,
      currentPeriodEnd: DateTime(2026, 10, 13, 12),
      winbackOfferEligible: winback,
    );

    // A cancelled row with its period still running: the Resubscribe home.
    Entitlement resubscribe({bool winback = true}) =>
        Entitlement(isPremium: true, subscription: row(winback: winback));

    // The period has ended: the Worker says no premium, and the screen is the paywall.
    Entitlement lapsed({bool trialSpent = true}) => Entitlement(
      isPremium: false,
      subscription: row(
        status: SubscriptionStatus.expired,
        trialSpent: trialSpent,
      ),
    );

    // Opens `location` (after `warmFirst`, if given) the way a tap's `go` does. `me` answers
    // `GET /me` in order and repeats its last answer; `meFails` makes every answer fail. Without
    // `settle`, it stops on the landing's first visible frame: the loading face spins, so settling
    // would pump straight through a slow reconcile.
    Future<GoRouter> land(
      WidgetTester tester, {
      List<Entitlement> me = const [],
      bool meFails = false,
      String location = landing,
      String? warmFirst,
      List<UpiApp> apps = const [_phonePe],
      bool settle = true,
    }) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues(const {});
      prefs = await SharedPreferences.getInstance();
      PremiumPurchase.clock = () => tester.binding.clock.now();
      addTearDown(() => PremiumPurchase.clock = DateTime.now);
      cancelOfferClock = () => tester.binding.clock.now();
      addTearDown(() => cancelOfferClock = DateTime.now);
      mockChannels(tester);
      api.initiate = {
        'merchantOrderId': 'DKS_WIN_1',
        'intentUrl': 'upi://mandate?tr=DKS_WIN_1&am=99',
        'trialEligible': false,
        'amountPaise': 9900,
      };

      final answers = [...me];
      final router = GoRouter(
        initialLocation: warmFirst ?? location,
        routes: [
          GoRoute(
            path: '/premium',
            builder: (_, state) => PremiumScreen(
              source: state.uri.queryParameters['source'] ?? 'unknown',
              offer: state.uri.queryParameters['offer'],
            ),
          ),
          // The feed reads `/me` before the tap: the cached answer the premium screen opens on.
          GoRoute(
            path: '/browse',
            builder: (_, _) => Consumer(
              builder: (_, ref, _) {
                ref.watch(entitlementDetailProvider);
                return const SizedBox();
              },
            ),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          // A failed `/me` stays failed: Riverpod's retry timers would outlive the test.
          retry: meFails ? (_, _) => null : null,
          overrides: [
            ...baseOverrides(),
            entitlementDetailProvider.overrideWith((ref) async {
              if (meFails) {
                throw const ApiException(
                  status: 503,
                  code: 'unavailable',
                  message: 'down',
                );
              }
              return answers.length > 1 ? answers.removeAt(0) : answers.single;
            }),
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
      if (warmFirst != null) {
        await tester.pumpAndSettle();
        router.go(location);
      }
      if (settle) {
        await tester.pumpAndSettle();
      } else {
        // A page pushed by `go` sits offstage for its first frame while heroes are measured.
        for (
          var i = 0;
          i < 3 && find.byType(PremiumScreen).evaluate().isEmpty;
          i++
        ) {
          await tester.pump();
        }
      }
      return router;
    }

    // Nothing the arrival is about to replace may paint while it waits on `/me`.
    void expectLoadingFace() {
      expect(find.byType(ArulPaywallLoading), findsOneWidget);
      expect(find.byType(ArulPaywallView), findsNothing);
      expect(find.byType(ArulMemberView), findsNothing);
      expect(find.byType(ArulResubscribeView), findsNothing);
      expect(find.text('Special offer'), findsNothing);
    }

    Future<void> closeSheet(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('cancel-offer-close')));
      await tester.pumpAndSettle();
    }

    testWidgets('the tap lands on the ₹99 sheet, and accepting is ₹99 through '
        'the chosen app', (tester) async {
      await land(tester, me: [resubscribe()]);

      expect(find.text('Special offer'), findsOneWidget);
      expect(api.bodiesOf('/payments/initiate'), isEmpty);
      // Opened by the push, not by the button: no `resubscribe_tapped`.
      expect(eventsNamed('resubscribe_tapped'), isEmpty);
      final shown = eventsNamed('cancel_offer_shown').single!;
      expect(shown['offer'], 'winback_99');
      expect(shown['flow'], 'winback');
      expect(shown['entry'], 'push');

      await tester.tap(find.text('Get 50% discount'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      final body = api.bodiesOf('/payments/initiate').single!;
      expect(body['offer'], 'winback_99');
      expect(body['targetApp'], 'com.phonepe.app');
      expect(eventsNamed('cancel_offer_accepted').single?['entry'], 'push');
      expect(
        eventsNamed('checkout_started').single?['paywall_source'],
        'winback_offer',
      );

      api.status = _statusRow('active', 9900);
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      await tester.pumpAndSettle();
    });

    testWidgets('it opens once: closed, it stays closed, and the button\'s own '
        'sheet carries no entry', (tester) async {
      await land(tester, me: [resubscribe()]);
      await closeSheet(tester);

      expect(find.text('Special offer'), findsNothing);
      expect(find.text('Resubscribe'), findsOneWidget);
      final declined = eventsNamed('cancel_offer_declined').single!;
      expect(declined['via'], 'close');
      expect(declined['entry'], 'push');
      expect(api.bodiesOf('/payments/initiate'), isEmpty);

      await tester.tap(find.text('Resubscribe'));
      await tester.pumpAndSettle();
      expect(find.text('Special offer'), findsOneWidget);
      final shown = eventsNamed('cancel_offer_shown');
      expect(shown, hasLength(2));
      expect(shown.last!.containsKey('entry'), isFalse);
      expect(eventsNamed('resubscribe_tapped'), hasLength(1));
    });

    testWidgets('a period that has ended opens it over the paywall', (
      tester,
    ) async {
      await land(tester, me: [lapsed()]);

      expect(find.text('Special offer'), findsOneWidget);
      expect(find.text('Resubscribe'), findsNothing);
      expect(eventsNamed('cancel_offer_shown').single?['entry'], 'push');
      await closeSheet(tester);
      expect(api.bodiesOf('/payments/initiate'), isEmpty);
    });

    testWidgets('with no UPI app, accepting is the ₹99 QR', (tester) async {
      await land(tester, me: [resubscribe()], apps: const []);
      expect(find.text('Special offer'), findsOneWidget);

      await tester.tap(find.text('Get 50% discount'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      final body = api.bodiesOf('/payments/initiate').single!;
      expect(body['offer'], 'winback_99');
      expect(body['mode'], 'qr');
      // Past the QR's own deadline and watch.
      await tester.pump(const Duration(minutes: 20));
      await tester.pumpAndSettle();
    });

    // The plan the app read before the revoke in the UPI app: still trialing, so no offer.
    Entitlement stale() => Entitlement(
      isPremium: true,
      subscription: row(status: SubscriptionStatus.trialing, winback: false),
    );

    Future<void> reconcile(WidgetTester tester) async {
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
    }

    // Frame by frame until the sheet is up: no frame may paint the cached plan, and the sheet only
    // ever rises over the fresh page, never over the loading face.
    Future<void> pumpUntilSheet(WidgetTester tester) async {
      for (var frames = 0; find.text('Special offer').evaluate().isEmpty;) {
        expect(++frames, lessThan(60), reason: 'the sheet never opened');
        await tester.pump(const Duration(milliseconds: 50));
        expect(find.byType(ArulMemberView), findsNothing);
      }
      expect(find.byType(ArulPaywallLoading), findsNothing);
      expect(find.byType(ArulResubscribeView), findsOneWidget);
      await tester.pumpAndSettle();
    }

    testWidgets(
      'a /me cached before the revoke never paints: the loading face '
      'holds through the reconcile, then the sheet rises over the fresh page',
      (tester) async {
        api.statusDelay = const Duration(seconds: 1);
        await land(
          tester,
          warmFirst: '/browse',
          me: [stale(), resubscribe()],
          settle: false,
        );
        expectLoadingFace();
        await tester.pump(const Duration(milliseconds: 900));
        expectLoadingFace();

        await pumpUntilSheet(tester);

        expect(eventsNamed('cancel_offer_shown').single?['entry'], 'push');
        expect(api.bodiesOf('/payments/status'), hasLength(1));
      },
    );

    testWidgets('a reconcile that hangs releases the loading face at 5 s; the '
        'sheet still waits for it', (tester) async {
      api.statusDelay = const Duration(seconds: 30);
      await land(
        tester,
        warmFirst: '/browse',
        me: [stale(), resubscribe()],
        settle: false,
      );
      await tester.pump(const Duration(milliseconds: 4900));
      expectLoadingFace();

      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(ArulPaywallLoading), findsNothing);
      expect(
        find.byType(ArulMemberView),
        findsOneWidget,
        reason: 'whatever /me says by then: the plan cached before the revoke',
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Special offer'),
        findsNothing,
        reason: 'the sheet is decided on the reconciled /me only',
      );

      await tester.pump(const Duration(seconds: 25));
      await tester.pumpAndSettle();
      expect(find.byType(ArulResubscribeView), findsOneWidget);
      expect(find.text('Special offer'), findsOneWidget);
      expect(eventsNamed('cancel_offer_shown').single?['entry'], 'push');
    });

    testWidgets('a tap while the screen is already up re-arms it: the loading '
        'face, a fresh /me, then the sheet', (tester) async {
      api.statusDelay = const Duration(seconds: 1);
      // Up since before the revoke: its open-time reconcile still read the live plan.
      final router = await land(
        tester,
        me: [stale(), stale(), resubscribe()],
        location: '/premium?source=push',
      );
      await reconcile(tester);
      expect(find.byType(ArulMemberView), findsOneWidget);
      expect(find.text('Special offer'), findsNothing);
      final screen = tester.state(find.byType(PremiumScreen));

      router.go(landing);
      await tester.pump();
      expectLoadingFace();

      await pumpUntilSheet(tester);

      expect(
        tester.state(find.byType(PremiumScreen)),
        same(screen),
        reason: 'go_router keeps the State, so didUpdateWidget must arm it',
      );
      expect(eventsNamed('cancel_offer_shown').single?['entry'], 'push');
      expect(api.bodiesOf('/payments/status'), hasLength(2));
    });

    void expectNothingOpened() {
      expect(find.text('Special offer'), findsNothing);
      expect(eventsNamed('cancel_offer_shown'), isEmpty);
      expect(api.bodiesOf('/payments/initiate'), isEmpty);
    }

    testWidgets('an ineligible arrival ends on its own page, with no loading '
        'face left', (tester) async {
      api.statusDelay = const Duration(seconds: 1);
      await land(tester, me: [resubscribe(winback: false)], settle: false);
      expectLoadingFace();

      await reconcile(tester);

      expect(find.byType(ArulPaywallLoading), findsNothing);
      expect(find.byType(ArulResubscribeView), findsOneWidget);
      expect(find.text('Resubscribe'), findsOneWidget);
      expectNothingOpened();
    });

    testWidgets('nothing opens for a trial-eligible row — the trial is the '
        'better deal', (tester) async {
      await land(tester, me: [lapsed(trialSpent: false)]);
      expectNothingOpened();
      expect(find.byType(ArulPaywallLoading), findsNothing);
      expect(find.byType(ArulPaywallView), findsOneWidget);
    });

    testWidgets('a /me that fails ends on the paywall, not the loading face', (
      tester,
    ) async {
      await land(tester, meFails: true);
      expectNothingOpened();
      expect(find.byType(ArulPaywallLoading), findsNothing);
      expect(find.byType(ArulPaywallView), findsOneWidget);
    });

    testWidgets('nothing opens without the offer in the link', (tester) async {
      await land(tester, me: [resubscribe()], location: '/premium?source=push');
      expectNothingOpened();
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
