// The long-press "Uninstall" shortcut. Its label must stay true: a tap lands on the ₹99 sheet (whose
// "Uninstall anyway" opens App info) or on App info itself, from every state the app can be in. The
// shortcut exists only while `/me` says premium ran out on someone offered ₹99.

import 'dart:async';

import 'package:arul/core/analytics/analytics_service.dart';
import 'package:arul/core/deeplink/deep_link_target.dart';
import 'package:arul/core/providers/locale_provider.dart';
import 'package:arul/data/models/app_config_model.dart';
import 'package:arul/data/models/subscription_model.dart';
import 'package:arul/data/repositories/repository_providers.dart';
import 'package:arul/features/premium/data/uninstall_shortcut_channel.dart';
import 'package:arul/features/premium/data/uninstall_shortcut_taps.dart';
import 'package:arul/features/premium/domain/entitlement.dart';
import 'package:arul/features/premium/domain/winback_reach.dart';
import 'package:arul/features/premium/providers/entitlement_provider.dart';
import 'package:arul/features/premium/providers/winback_reach_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

class _FakeChannel implements UninstallShortcutChannel {
  String? parked;
  int appInfoOpens = 0;
  final syncs = <({bool publish, String shortLabel, String longLabel})>[];

  @override
  Future<String?> takePendingTap() async {
    final tap = parked;
    parked = null;
    return tap;
  }

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
  }) async {
    syncs.add((publish: publish, shortLabel: shortLabel, longLabel: longLabel));
    return null;
  }
}

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

class _English extends LocaleNotifier {
  @override
  Locale build() => const Locale('en');
}

Entitlement _lapsed({bool premium = false}) => Entitlement(
  isPremium: premium,
  subscription: SubscriptionModel(
    id: 'sub_1',
    userId: 'u_1',
    status: SubscriptionStatus.cancelled,
    trialEnd: DateTime(2026, 9, 1),
    currentPeriodEnd: DateTime(2026, 10, 1),
    winbackOfferEligible: true,
  ),
);

AppConfigModel _config(Map<String, dynamic> flags) =>
    AppConfigModel(prices: const {}, policyUrls: const {}, featureFlags: flags);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeChannel channel;
  late _RecordingAnalytics analytics;

  setUp(() {
    ArulDeepLink.reset();
    channel = _FakeChannel();
    analytics = _RecordingAnalytics();
  });

  tearDown(ArulDeepLink.reset);

  group('a tap', () {
    late List<Uri> premiumOpens;

    Future<(GoRouter, UninstallShortcutTaps)> appAt(
      WidgetTester tester,
      String location, {
      Future<Entitlement> Function()? me,
      WinbackReachFlags flags = const WinbackReachFlags(),
    }) async {
      premiumOpens = [];
      Widget page(String name) => Scaffold(body: Text(name));
      final router = GoRouter(
        initialLocation: location,
        routes: [
          GoRoute(path: '/', builder: (_, _) => page('splash')),
          GoRoute(path: '/browse', builder: (_, _) => page('feed')),
          GoRoute(path: '/sign-in', builder: (_, _) => page('wall')),
          GoRoute(
            path: '/premium',
            builder: (_, state) {
              premiumOpens.add(state.uri);
              return page('premium');
            },
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      final taps = UninstallShortcutTaps(
        channel: channel,
        router: router,
        entitlement: me ?? () async => _lapsed(),
        flags: () => flags,
        analytics: analytics,
      );
      return (router, taps);
    }

    Map<String, Object?>? landed() =>
        analytics.events.where((e) => e.$1 == 'deep_link_opened').single.$2;

    testWidgets('nothing parked: nothing happens', (tester) async {
      final (_, taps) = await appAt(tester, '/browse');
      await taps.take();
      await tester.pumpAndSettle();
      expect(premiumOpens, isEmpty);
      expect(channel.appInfoOpens, 0);
      expect(analytics.events, isEmpty);
    });

    testWidgets('on the feed, offered ₹99: the Uninstall door', (tester) async {
      final (_, taps) = await appAt(tester, '/browse');
      channel.parked = UninstallShortcutChannel.tapOffer;
      await taps.take();
      await tester.pumpAndSettle();

      expect(premiumOpens.single.queryParameters, {
        'source': WinbackEntry.uninstallSource,
        'offer': 'winback_99',
      });
      expect(channel.appInfoOpens, 0);
      expect(landed(), {'kind': 'premium', 'source': 'shortcut'});
      expect(ArulDeepLink.landedThisLaunch, isTrue);
    });

    testWidgets('a cold tap waits out the splash, then lands', (tester) async {
      final (router, taps) = await appAt(tester, '/');
      channel.parked = UninstallShortcutChannel.tapOffer;
      unawaited(taps.take());
      await tester.pump(const Duration(seconds: 2));
      expect(premiumOpens, isEmpty);

      router.go('/browse');
      await tester.pumpAndSettle();
      expect(premiumOpens, hasLength(1));
    });

    testWidgets('a splash that never routes ends in App info', (tester) async {
      final (_, taps) = await appAt(tester, '/');
      channel.parked = UninstallShortcutChannel.tapOffer;
      unawaited(taps.take());
      await tester.pump(
        UninstallShortcutTaps.holdLimit + const Duration(seconds: 1),
      );
      await tester.pumpAndSettle();
      expect(premiumOpens, isEmpty);
      expect(channel.appInfoOpens, 1);
    });

    for (final (where, at) in [
      ('on the sign-in wall', '/sign-in'),
      ('already on the paywall', '/premium'),
    ]) {
      testWidgets('$where: App info', (tester) async {
        final (_, taps) = await appAt(tester, at);
        premiumOpens.clear();
        channel.parked = UninstallShortcutChannel.tapOffer;
        await taps.take();
        await tester.pumpAndSettle();
        expect(premiumOpens, isEmpty);
        expect(channel.appInfoOpens, 1);
        expect(landed(), {'kind': 'app_info', 'source': 'shortcut'});
      });
    }

    testWidgets('premium again, or the switch off: App info', (tester) async {
      var (_, taps) = await appAt(
        tester,
        '/browse',
        me: () async => _lapsed(premium: true),
      );
      channel.parked = UninstallShortcutChannel.tapOffer;
      await taps.take();
      await tester.pumpAndSettle();
      expect(channel.appInfoOpens, 1);

      (_, taps) = await appAt(
        tester,
        '/browse',
        flags: const WinbackReachFlags(uninstallShortcut: false),
      );
      channel.parked = UninstallShortcutChannel.tapOffer;
      await taps.take();
      await tester.pumpAndSettle();
      expect(channel.appInfoOpens, 2);
      expect(premiumOpens, isEmpty);
    });

    testWidgets('a /me that never answers ends in App info', (tester) async {
      final never = Completer<Entitlement>();
      final (_, taps) = await appAt(tester, '/browse', me: () => never.future);
      channel.parked = UninstallShortcutChannel.tapOffer;
      unawaited(taps.take());
      await tester.pump(
        UninstallShortcutTaps.entitlementWait + const Duration(seconds: 1),
      );
      await tester.pumpAndSettle();
      expect(channel.appInfoOpens, 1);
      expect(premiumOpens, isEmpty);
    });

    testWidgets(
      'a tap the native side already sent to App info is only counted',
      (tester) async {
        final (_, taps) = await appAt(tester, '/browse');
        channel.parked = UninstallShortcutChannel.tapAppInfo;
        await taps.take();
        await tester.pumpAndSettle();
        expect(channel.appInfoOpens, 0, reason: 'native opened it');
        expect(premiumOpens, isEmpty);
        expect(landed(), {'kind': 'app_info', 'source': 'shortcut'});
      },
    );
  });

  group('the sync', () {
    Future<ProviderContainer> containerWith({
      FutureOr<Entitlement> Function()? me,
      Map<String, dynamic> flags = const {},
    }) async {
      final container = ProviderContainer(
        retry: (_, _) => null,
        overrides: [
          uninstallShortcutChannelProvider.overrideWithValue(channel),
          entitlementDetailProvider.overrideWith(
            (ref) async => (me ?? _lapsed)(),
          ),
          appConfigProvider.overrideWithBuild((ref, _) async => _config(flags)),
          localeProvider.overrideWith(_English.new),
        ],
      );
      addTearDown(container.dispose);
      await container.read(appConfigProvider.future);
      return container;
    }

    Future<void> run(ProviderContainer container) async {
      try {
        await container.read(entitlementDetailProvider.future);
      } catch (_) {}
      await container.read(uninstallShortcutSyncProvider.future);
    }

    test(
      'premium ran out on someone offered ₹99: published, in the app\'s words',
      () async {
        await run(await containerWith());
        expect(channel.syncs.single, (
          publish: true,
          shortLabel: 'Uninstall',
          longLabel: 'Uninstall Arul',
        ));
      },
    );

    test('premium, signed out, or switched off: removed', () async {
      await run(await containerWith(me: () => _lapsed(premium: true)));
      await run(await containerWith(me: () => const Entitlement.none()));
      await run(
        await containerWith(
          flags: const {
            'winback_reach': {'uninstall_shortcut': false},
          },
        ),
      );
      expect([for (final s in channel.syncs) s.publish], [false, false, false]);
    });

    test('no verdict on /me: the phone is left as it is', () async {
      await run(await containerWith(me: () => throw StateError('offline')));
      expect(channel.syncs, isEmpty);
    });
  });
}
