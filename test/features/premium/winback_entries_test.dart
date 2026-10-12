// The ₹99 win-back sheet opened by a door no pay tap opened: a premium tap, the app-open sheet and the
// "Uninstall" shortcut. None of them may start a checkout nobody accepted; the sheet-only doors rise
// over the page the person was on and return them there; "Uninstall" always reaches App info.

import 'dart:async';

import 'package:arul/app/l10n/app_localizations.dart';
import 'package:arul/app/router.dart';
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
import 'package:arul/features/premium/data/uninstall_shortcut_channel.dart';
import 'package:arul/features/premium/domain/entitlement.dart';
import 'package:arul/features/premium/presentation/cancel_offer_sheet.dart';
import 'package:arul/features/premium/presentation/paywall_view.dart';
import 'package:arul/features/premium/presentation/premium_screen.dart';
import 'package:arul/features/premium/providers/entitlement_provider.dart';
import 'package:arul/features/premium/providers/premium_purchase_provider.dart';
import 'package:arul/features/premium/providers/trial_conversion_catch_up.dart';
import 'package:arul/features/premium/providers/winback_reach_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
    'merchant_order_id': 'DKS_WIN_1',
    'price_paise': pricePaise,
    'trial_end': DateTime(2026, 9, 1).toIso8601String(),
  },
};

class _FakeApi extends ApiClient {
  final posts = <(String, Map<String, dynamic>?)>[];
  Map<String, dynamic> status = _statusRow('cancelled', 19900);

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
    return switch (path) {
      '/payments/initiate' => {
        'merchantOrderId': 'DKS_WIN_1',
        'intentUrl': 'upi://mandate?tr=DKS_WIN_1&am=99',
        'trialEligible': false,
        'amountPaise': 9900,
      },
      '/payments/status' => status,
      '/payments/abandon' => {'settled': false},
      _ => <String, dynamic>{},
    };
  }
}

class _FakeShortcutChannel implements UninstallShortcutChannel {
  int appInfoOpens = 0;

  @override
  Future<bool> openAppInfo() async {
    appInfoOpens++;
    return true;
  }

  @override
  Future<UninstallShortcutState?> sync({
    required bool publish,
    required String shortLabel,
    required String longLabel,
  }) async => null;

  @override
  Future<String?> takePendingTap() async => null;
}

const _upiChannel = MethodChannel('com.hsrutility.arul/upi_intent');
const _phonePe = UpiApp(packageName: 'com.phonepe.app', label: 'PhonePe');

SubscriptionModel _row({
  SubscriptionStatus status = SubscriptionStatus.expired,
  bool winback = true,
}) => SubscriptionModel(
  id: 'sub_1',
  userId: 'u_1',
  status: status,
  merchantOrderId: 'DKS_ORIGINAL',
  trialEnd: DateTime(2026, 9, 1),
  currentPeriodEnd: DateTime(2026, 10, 1),
  winbackOfferEligible: winback,
);

// Premium has run out: the Worker says no premium and still offers ₹99.
Entitlement _lapsed({SubscriptionStatus status = SubscriptionStatus.expired}) =>
    Entitlement(isPremium: false, subscription: _row(status: status));

void main() {
  late _RecordingAnalytics analytics;
  late _FakeApi api;
  late _FakeShortcutChannel shortcut;
  late SharedPreferences prefs;

  // A lapsed period lands on the paywall, laid out for its own faces.
  setUpAll(loadRealFonts);

  setUp(() {
    analytics = _RecordingAnalytics();
    api = _FakeApi();
    shortcut = _FakeShortcutChannel();
  });

  List<Map<String, Object?>?> eventsNamed(String name) =>
      analytics.events.where((e) => e.$1 == name).map((e) => e.$2).toList();

  // Opens `/browse` (the page a door rises over), then pushes [location] the way the gates, the
  // app-open trigger and the shortcut do.
  Future<void> open(
    WidgetTester tester,
    String location, {
    Entitlement? me,
    Map<String, dynamic> flags = const {},
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
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      _upiChannel,
      (call) async => call.method == 'launch' ? true : null,
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

    final router = GoRouter(
      initialLocation: '/browse',
      routes: [
        GoRoute(
          path: '/premium',
          pageBuilder: (_, state) => premiumPage(state),
        ),
        GoRoute(
          path: '/browse',
          builder: (_, _) => const Scaffold(body: Text('the feed')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          apiClientProvider.overrideWith((ref) => api),
          analyticsServiceProvider.overrideWith((ref) => analytics),
          appConfigProvider.overrideWithBuild(
            (ref, _) async => AppConfigModel(
              prices: const {
                'monthly': {'amount': 19900},
              },
              policyUrls: const <String, dynamic>{},
              featureFlags: flags,
            ),
          ),
          trialConversionCatchUpProvider.overrideWithValue(
            TrialConversionCatchUp(
              prefs: prefs,
              analytics: analytics,
              monthlyPriceRupees: () => 199,
            ),
          ),
          entitlementDetailProvider.overrideWith(
            (ref) async => me ?? _lapsed(),
          ),
          installedUpiAppsProvider.overrideWith(
            (ref) async => const UpiScan(apps: [_phonePe], otherPackages: []),
          ),
          uninstallShortcutChannelProvider.overrideWithValue(shortcut),
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
    unawaited(router.push(location));
    await tester.pumpAndSettle();
  }

  // Whether the door's screen is gone and they are back on the page it rose over.
  bool onFeed() => find.byType(PremiumScreen).evaluate().isEmpty;

  Finder sheet() => find.text('Special offer');

  void expectNothingStarted() =>
      expect(api.bodiesOf('/payments/initiate'), isEmpty);

  group('a premium tap', () {
    const location = '/premium?source=apply&offer=winback_99';

    testWidgets('opens the ₹99 sheet over the paywall, hold and all', (
      tester,
    ) async {
      await open(tester, location);

      expect(sheet(), findsOneWidget);
      expect(find.byType(ArulPaywallView), findsOneWidget);
      expect(find.textContaining('Offer ends in'), findsOneWidget);
      expect(find.text('Limited time pricing'), findsOneWidget);
      final shown = eventsNamed('cancel_offer_shown').single!;
      expect(shown['offer'], 'winback_99');
      expect(shown['entry'], 'premium_tap');
      expectNothingStarted();
    });

    testWidgets("\"I don't want the offer\" only closes: no ₹199 start", (
      tester,
    ) async {
      await open(tester, location);
      await tester.tap(find.text("I don't want the offer"));
      await tester.pumpAndSettle();

      expect(sheet(), findsNothing);
      expect(find.byType(ArulPaywallView), findsOneWidget);
      expect(onFeed(), isFalse, reason: 'they came for premium');
      final declined = eventsNamed('cancel_offer_declined').single!;
      expect(declined['via'], 'link');
      expect(declined['entry'], 'premium_tap');
      expectNothingStarted();
    });

    testWidgets('accepting is the ₹99 sale', (tester) async {
      await open(tester, location);
      await tester.tap(find.text('Get 50% discount'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(api.bodiesOf('/payments/initiate').single!['offer'], 'winback_99');
      expect(
        eventsNamed('cancel_offer_accepted').single?['entry'],
        'premium_tap',
      );
      api.status = _statusRow('active', 9900);
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      await tester.pumpAndSettle();
    });

    testWidgets('a setup in flight opens nothing', (tester) async {
      await open(
        tester,
        location,
        me: _lapsed(status: SubscriptionStatus.pending),
      );
      expect(sheet(), findsNothing);
      expect(find.byType(ArulPaywallView), findsOneWidget);
      expect(eventsNamed('cancel_offer_shown'), isEmpty);
    });

    testWidgets('countdown off: no hold and no "limited time" line', (
      tester,
    ) async {
      await open(
        tester,
        location,
        flags: const {
          'winback_reach': {'countdown': false},
        },
      );
      expect(sheet(), findsOneWidget);
      expect(find.textContaining('Offer ends in'), findsNothing);
      expect(find.text('Limited time pricing'), findsNothing);
    });
  });

  group('the app-open sheet', () {
    const location = '/premium?source=app_open&offer=winback_99';

    testWidgets('rises over the page they were on, with no paywall behind it', (
      tester,
    ) async {
      await open(tester, location);

      expect(sheet(), findsOneWidget);
      expect(find.byType(ArulPaywallView), findsNothing);
      expect(find.text('the feed'), findsOneWidget);
      expect(eventsNamed('cancel_offer_shown').single?['entry'], 'app_open');
    });

    testWidgets('the X returns them to the feed', (tester) async {
      await open(tester, location);
      await tester.tap(find.byKey(const ValueKey('cancel-offer-close')));
      await tester.pumpAndSettle();

      expect(onFeed(), isTrue);
      expect(find.byType(PremiumScreen), findsNothing);
      expect(eventsNamed('cancel_offer_declined').single?['via'], 'close');
      expectNothingStarted();
    });

    testWidgets('back does the same', (tester) async {
      await open(tester, location);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(onFeed(), isTrue);
      expect(eventsNamed('cancel_offer_declined').single?['via'], 'dismiss');
      expectNothingStarted();
    });

    testWidgets('accepting brings the paywall up under the UPI handoff', (
      tester,
    ) async {
      await open(tester, location);
      await tester.tap(find.text('Get 50% discount'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(api.bodiesOf('/payments/initiate').single!['offer'], 'winback_99');
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(ArulPaywallView), findsOneWidget);
      api.status = _statusRow('active', 9900);
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      await tester.pumpAndSettle();
    });

    testWidgets(
      'someone premium again gets nothing, and stays where they were',
      (tester) async {
        await open(
          tester,
          location,
          me: Entitlement(isPremium: true, subscription: _row()),
        );
        expect(sheet(), findsNothing);
        expect(onFeed(), isTrue);
        expect(eventsNamed('cancel_offer_shown'), isEmpty);
      },
    );
  });

  group('the Uninstall shortcut', () {
    const location = '/premium?source=uninstall_shortcut&offer=winback_99';

    testWidgets('"Uninstall anyway" takes the decline link\'s place', (
      tester,
    ) async {
      await open(tester, location);

      expect(sheet(), findsOneWidget);
      expect(
        find.byKey(const ValueKey('cancel-offer-uninstall')),
        findsOneWidget,
      );
      expect(find.text('Uninstall anyway'), findsOneWidget);
      expect(find.text("I don't want the offer"), findsNothing);
      expect(find.byType(ArulPaywallView), findsNothing);
      expect(
        eventsNamed('cancel_offer_shown').single?['entry'],
        'uninstall_shortcut',
      );
    });

    testWidgets('"Uninstall anyway" opens App info and leaves the screen', (
      tester,
    ) async {
      await open(tester, location);
      await tester.tap(find.byKey(const ValueKey('cancel-offer-uninstall')));
      await tester.pumpAndSettle();

      expect(shortcut.appInfoOpens, 1);
      expect(onFeed(), isTrue);
      final declined = eventsNamed('cancel_offer_declined').single!;
      expect(declined['via'], 'uninstall');
      expect(declined['entry'], 'uninstall_shortcut');
      expectNothingStarted();
    });

    testWidgets('"Uninstall anyway" still works after the hold runs out', (
      tester,
    ) async {
      await open(tester, location);
      await tester.pump(const Duration(minutes: 10, seconds: 1));
      expect(find.text('Offer ended'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('cancel-offer-uninstall')));
      await tester.pumpAndSettle();
      expect(shortcut.appInfoOpens, 1);
    });

    testWidgets('the X keeps the app: no App info', (tester) async {
      await open(tester, location);
      await tester.tap(find.byKey(const ValueKey('cancel-offer-close')));
      await tester.pumpAndSettle();

      expect(shortcut.appInfoOpens, 0);
      expect(onFeed(), isTrue);
    });

    testWidgets('no ₹99 to offer: straight to App info, never a dead end', (
      tester,
    ) async {
      await open(
        tester,
        location,
        me: Entitlement(isPremium: true, subscription: _row()),
      );
      expect(sheet(), findsNothing);
      expect(shortcut.appInfoOpens, 1);
      expect(onFeed(), isTrue);
    });
  });

  group('the push', () {
    testWidgets("its \"I don't want the offer\" only closes now", (
      tester,
    ) async {
      await open(tester, '/premium?source=push&offer=winback_99');
      expect(eventsNamed('cancel_offer_shown').single?['entry'], 'push');
      await tester.tap(find.text("I don't want the offer"));
      await tester.pumpAndSettle();

      expect(sheet(), findsNothing);
      expect(eventsNamed('cancel_offer_declined').single?['via'], 'link');
      expectNothingStarted();
    });

    testWidgets('keeps its hold when the countdown switch is off', (
      tester,
    ) async {
      await open(
        tester,
        '/premium?source=push&offer=winback_99',
        flags: const {
          'winback_reach': {'countdown': false},
        },
      );
      expect(sheet(), findsOneWidget);
      expect(find.textContaining('Offer ends in'), findsOneWidget);
    });
  });
}
