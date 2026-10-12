// The daily ₹99 sheet: one ask per process, only for someone whose premium has run out, at most
// once per IST day, and never on a launch another unrequested surface (the push-permission ask,
// Play's review sheet) already took. The trigger opens it from the plain feed only.

import 'dart:async';

import 'package:arul/core/deeplink/deep_link_target.dart';
import 'package:arul/core/launch/launch_moment.dart';
import 'package:arul/core/update/update_holds.dart';
import 'package:arul/data/models/subscription_model.dart';
import 'package:arul/features/premium/domain/entitlement.dart';
import 'package:arul/features/premium/domain/winback_daily_controller.dart';
import 'package:arul/features/premium/domain/winback_ledger.dart';
import 'package:arul/features/premium/domain/winback_reach.dart';
import 'package:arul/features/premium/presentation/winback_daily_trigger.dart';
import 'package:arul/features/premium/providers/winback_reach_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

Entitlement _lapsed({SubscriptionStatus status = SubscriptionStatus.expired}) =>
    Entitlement(
      isPremium: false,
      subscription: SubscriptionModel(
        id: 'sub_1',
        userId: 'u_1',
        status: status,
        trialEnd: DateTime(2026, 9, 1),
        currentPeriodEnd: DateTime(2026, 10, 1),
        winbackOfferEligible: true,
      ),
    );

void main() {
  late SharedPreferences prefs;
  late WinbackLedger ledger;
  late LaunchMoment moment;
  late int opens;

  setUp(() async {
    SharedPreferences.setMockInitialValues(const {});
    prefs = await SharedPreferences.getInstance();
    ledger = WinbackLedger(prefs);
    moment = LaunchMoment();
    opens = 0;
  });

  WinbackDailyController controller({
    Future<Entitlement> Function()? me,
    WinbackReachFlags flags = const WinbackReachFlags(),
  }) => WinbackDailyController(
    ledger: ledger,
    moment: moment,
    entitlement: me ?? () async => _lapsed(),
    flags: () => flags,
  );

  Future<WinbackDailyOutcome> ask(
    WinbackDailyController c, {
    bool Function()? surfaceClear,
  }) => c.maybeShow(
    surfaceClear: surfaceClear ?? () => true,
    open: () => opens++,
  );

  group('the controller', () {
    test(
      'a lapsed returning user on a clear feed gets it, once per process',
      () async {
        final c = controller();
        expect(await ask(c), WinbackDailyOutcome.shown);
        expect(opens, 1);
        expect(moment.takenBy, 'winback_daily');
        expect(await ask(c), WinbackDailyOutcome.alreadyEvaluated);
        expect(opens, 1);
      },
    );

    test('the switch off: nothing', () async {
      expect(
        await ask(
          controller(flags: const WinbackReachFlags(dailySheet: false)),
        ),
        WinbackDailyOutcome.switchedOff,
      );
      expect(opens, 0);
    });

    test(
      'anyone not reachable: premium, mid-setup, or no /me at all',
      () async {
        for (final me in <Future<Entitlement> Function()>[
          () async => Entitlement(
            isPremium: true,
            subscription: _lapsed().subscription,
          ),
          () async => _lapsed(status: SubscriptionStatus.pending),
          () async => const Entitlement.none(),
          () async => throw StateError('offline'),
        ]) {
          expect(
            await ask(controller(me: me)),
            WinbackDailyOutcome.notReachable,
          );
        }
        expect(opens, 0);
        expect(moment.takenBy, isNull);
      },
    );

    test('already shown today, from any door: not again', () async {
      await ledger.noteShown();
      expect(await ask(controller()), WinbackDailyOutcome.notToday);
      expect(opens, 0);
    });

    test(
      'a surface that covers the feed, before or after /me, skips it',
      () async {
        expect(
          await ask(controller(), surfaceClear: () => false),
          WinbackDailyOutcome.blocked,
        );
        var reads = 0;
        expect(
          await ask(controller(), surfaceClear: () => ++reads == 1),
          WinbackDailyOutcome.blocked,
        );
        expect(opens, 0);
        expect(moment.takenBy, isNull);
      },
    );

    test(
      'a launch the review already took keeps the sheet for another day',
      () async {
        expect(moment.take('review'), isTrue);
        expect(await ask(controller()), WinbackDailyOutcome.momentTaken);
        expect(opens, 0);
        expect(ledger.canAutoShow(), isTrue);
      },
    );

    testWidgets(
      'a /me slower than the wait costs this launch, never a late pop-up',
      (tester) async {
        final never = Completer<Entitlement>();
        final pending = ask(controller(me: () => never.future));
        await tester.pump(
          WinbackDailyController.entitlementWait + const Duration(seconds: 1),
        );
        expect(await pending, WinbackDailyOutcome.notReachable);
        expect(opens, 0);
      },
    );
  });

  group('the trigger', () {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    late List<Uri> opened;
    late ValueNotifier<bool> hostReady;

    setUp(() {
      ArulDeepLink.reset();
      opened = [];
      hostReady = ValueNotifier(true);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    });

    tearDown(() {
      ArulDeepLink.reset();
      UpdateHolds.launch.value = UpdateLaunch.clear;
    });

    Future<void> pumpFeed(WidgetTester tester) async {
      final router = GoRouter(
        initialLocation: '/browse',
        routes: [
          GoRoute(
            path: '/browse',
            builder: (_, _) => _Feed(hostReady: hostReady),
          ),
          GoRoute(
            path: '/premium',
            builder: (_, state) {
              opened.add(state.uri);
              return const SizedBox();
            },
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            winbackDailyControllerProvider.overrideWithValue(controller()),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
    }

    testWidgets('opens the daily door after the settle, on the plain feed', (
      tester,
    ) async {
      await pumpFeed(tester);
      await tester.pump(
        winbackDailySettleDelay - const Duration(milliseconds: 1),
      );
      expect(opened, isEmpty, reason: 'inside the settle window');

      await tester.pump(const Duration(milliseconds: 1));
      await tester.pumpAndSettle();
      expect(opened.single.queryParameters, {
        'source': WinbackEntry.dailySource,
        'offer': 'winback_99',
      });
    });

    testWidgets('waits for this launch\'s update check, then decides', (
      tester,
    ) async {
      UpdateHolds.launch.value = UpdateLaunch.undecided;
      await pumpFeed(tester);
      await tester.pump(winbackDailySettleDelay);
      await tester.pumpAndSettle();
      expect(opened, isEmpty);

      UpdateHolds.launch.value = UpdateLaunch.clear;
      await tester.pumpAndSettle();
      expect(opened, hasLength(1));
    });

    testWidgets('an update prompt on this launch: no sheet', (tester) async {
      UpdateHolds.launch.value = UpdateLaunch.undecided;
      await pumpFeed(tester);
      await tester.pump(winbackDailySettleDelay);
      UpdateHolds.launch.value = UpdateLaunch.prompted;
      await tester.pumpAndSettle();
      expect(opened, isEmpty);
    });

    testWidgets('a link or push landing skips this launch', (tester) async {
      ArulDeepLink.noteExternalOpen();
      await pumpFeed(tester);
      await tester.pump(winbackDailySettleDelay);
      await tester.pumpAndSettle();
      expect(opened, isEmpty);
    });

    testWidgets('the feed not ready: skipped', (tester) async {
      hostReady.value = false;
      await pumpFeed(tester);
      await tester.pump(winbackDailySettleDelay);
      await tester.pumpAndSettle();
      expect(opened, isEmpty);
    });
  });
}

class _Feed extends ConsumerStatefulWidget {
  const _Feed({required this.hostReady});

  final ValueNotifier<bool> hostReady;

  @override
  ConsumerState<_Feed> createState() => _FeedState();
}

class _FeedState extends ConsumerState<_Feed> with WinbackDailyTrigger {
  @override
  bool winbackDailyHostReady() => widget.hostReady.value;

  @override
  Widget build(BuildContext context) {
    maybeScheduleWinbackDaily();
    return const Text('feed');
  }
}
