// ensurePremium() is THE client gate (CLAUDE.md §5) -> these are the contracts it has to hold.
// It AWAITS entitlementProvider.future -> a loading entitlement must never bounce a paying user on cold start.
// Not premium -> exactly one `${source}_blocked_premium` event with the caller's attribution, then /premium?source=.
// Premium -> true, no event, no navigation.
// An entitlement fetch failure fails CLOSED into the paywall -> the Worker's /media/signed-url stays authoritative.

import 'dart:async';

import 'package:arul/core/analytics/analytics_provider.dart';
import 'package:arul/core/analytics/analytics_service.dart';
import 'package:arul/data/models/app_config_model.dart';
import 'package:arul/data/models/subscription_model.dart';
import 'package:arul/data/repositories/repository_providers.dart';
import 'package:arul/features/premium/domain/entitlement.dart';
import 'package:arul/features/premium/providers/entitlement_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

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

void main() {
  late _RecordingAnalytics analytics;
  late List<String> paywallSources;
  late List<String?> paywallOffers;
  late BuildContext gateContext;
  late WidgetRef gateRef;

  /// Pumps a tiny app whose home captures a (context, ref) pair and whose /premium route records its source.
  /// That asserts the REAL navigation, never a mock of it.
  ///
  /// [detail] answers the full `/me` instead, the way the app derives the gate's bool from it, and
  /// [flags] is the remote config's `feature_flags`.
  Future<void> pumpGateHarness(
    WidgetTester tester, {
    FutureOr<bool> Function()? entitlement,
    Entitlement? detail,
    Map<String, dynamic> flags = const {},
  }) async {
    analytics = _RecordingAnalytics();
    paywallSources = [];
    paywallOffers = [];
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => Consumer(
            builder: (context, ref, _) {
              gateContext = context;
              gateRef = ref;
              return const SizedBox.shrink();
            },
          ),
        ),
        GoRoute(
          path: '/premium',
          builder: (context, state) {
            paywallSources.add(state.uri.queryParameters['source'] ?? '');
            paywallOffers.add(state.uri.queryParameters['offer']);
            return const SizedBox.shrink();
          },
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          analyticsServiceProvider.overrideWithValue(analytics),
          if (entitlement != null)
            entitlementProvider.overrideWith((ref) async => entitlement()),
          if (detail != null)
            entitlementDetailProvider.overrideWith((ref) async => detail),
          appConfigProvider.overrideWithBuild(
            (ref, _) async => AppConfigModel(
              prices: const {},
              policyUrls: const {},
              featureFlags: flags,
            ),
          ),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
  }

  testWidgets(
    'awaits the entitlement future: while the read is still loading the gate '
    'gives NO answer, and a late true never shows the paywall',
    (tester) async {
      // The entitlement read is gated open by hand -> the exact cold-start moment a loading snapshot would bounce a payer.
      final entitled = Completer<bool>();
      await pumpGateHarness(tester, entitlement: () => entitled.future);

      bool? answer;
      unawaited(
        ensurePremium(
          gateContext,
          gateRef,
          source: 'apply',
        ).then((v) => answer = v),
      );
      await tester.pump();
      await tester.pump();
      expect(
        answer,
        isNull,
        reason:
            'the gate must not answer from a loading snapshot — awaiting the '
            'future is the whole point of its signature',
      );
      expect(paywallSources, isEmpty);

      entitled.complete(true);
      await tester.pumpAndSettle();

      expect(answer, isTrue);
      expect(analytics.events, isEmpty, reason: 'no blocked event for premium');
      expect(paywallSources, isEmpty, reason: 'no paywall for premium');
    },
  );

  testWidgets('not premium: false, one source_blocked_premium event with the '
      'attribution properties, and a route to /premium?source=', (
    tester,
  ) async {
    await pumpGateHarness(tester, entitlement: () => false);

    final answer = await ensurePremium(
      gateContext,
      gateRef,
      source: 'apply',
      properties: {'wallpaper_id': 'w-42'},
    );
    await tester.pumpAndSettle();

    expect(answer, isFalse);
    expect(analytics.events, hasLength(1));
    final (event, properties) = analytics.events.single;
    expect(event, 'apply_blocked_premium');
    expect(properties, {'wallpaper_id': 'w-42'});
    expect(paywallSources, ['apply']);
  });

  testWidgets(
    'an entitlement fetch failure fails closed: paywall UX, not a crash and '
    'not a free pass',
    (tester) async {
      await pumpGateHarness(
        tester,
        entitlement: () => throw StateError('network down'),
      );

      final answer = await ensurePremium(gateContext, gateRef, source: 'share');
      await tester.pumpAndSettle();

      expect(answer, isFalse);
      expect(analytics.events.single.$1, 'share_blocked_premium');
      expect(paywallSources, ['share']);
    },
  );

  // A lapsed returning user's blocked action opens the paywall on the ₹99 win-back sheet; everyone
  // else, and every doubtful read, keeps the plain paywall.
  group('the ₹99 win-back first', () {
    SubscriptionModel row(
      SubscriptionStatus status, {
      bool trialSpent = true,
    }) => SubscriptionModel(
      id: 'sub_1',
      userId: 'u_1',
      status: status,
      trialEnd: trialSpent ? DateTime(2026, 9, 1) : null,
      currentPeriodEnd: DateTime(2026, 10, 1),
      winbackOfferEligible: true,
    );

    Future<void> gate(
      WidgetTester tester,
      Entitlement detail, {
      Map<String, dynamic> flags = const {},
    }) async {
      await pumpGateHarness(tester, detail: detail, flags: flags);
      final container = ProviderScope.containerOf(gateContext);
      await container.read(appConfigProvider.future);
      final answer = await ensurePremium(gateContext, gateRef, source: 'apply');
      await tester.pumpAndSettle();
      expect(answer, isFalse);
      expect(paywallSources, ['apply']);
    }

    testWidgets('premium has run out: the paywall opens on the offer', (
      tester,
    ) async {
      await gate(
        tester,
        Entitlement(
          isPremium: false,
          subscription: row(SubscriptionStatus.expired),
        ),
      );
      expect(paywallOffers, ['winback_99']);
    });

    testWidgets('a new user keeps the trial paywall', (tester) async {
      await gate(
        tester,
        Entitlement(
          isPremium: false,
          subscription: row(SubscriptionStatus.expired, trialSpent: false),
        ),
      );
      expect(paywallOffers, [null]);
    });

    testWidgets('a setup in flight keeps the plain paywall', (tester) async {
      await gate(
        tester,
        Entitlement(
          isPremium: false,
          subscription: row(SubscriptionStatus.pending),
        ),
      );
      expect(paywallOffers, [null]);
    });

    testWidgets('tap_first off keeps the plain paywall', (tester) async {
      await gate(
        tester,
        Entitlement(
          isPremium: false,
          subscription: row(SubscriptionStatus.expired),
        ),
        flags: const {
          'winback_reach': {'tap_first': false},
        },
      );
      expect(paywallOffers, [null]);
    });
  });
}
