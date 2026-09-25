// The trigger asks only once the home surface has loaded, after the settle delay, and only when
// nothing sits above it: a sheet, a dialog, a pushed route or a link landing skips THIS cold open
// and leaves the ask pending for the next one.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:arul/core/analytics/analytics_provider.dart';
import 'package:arul/core/deeplink/deep_link_target.dart';
import 'package:arul/core/update/update_holds.dart';
import 'package:arul/features/review/domain/review_ledger.dart';
import 'package:arul/features/review/presentation/review_prompt_trigger.dart';
import 'package:arul/features/review/providers/review_prompt_controller.dart';

import 'review_fakes.dart';

class _Home extends ConsumerStatefulWidget {
  const _Home({required this.loaded, required this.hostReady});

  final ValueNotifier<bool> loaded;
  final ValueNotifier<bool> hostReady;

  @override
  ConsumerState<_Home> createState() => _HomeState();
}

class _HomeState extends ConsumerState<_Home> with ReviewPromptTrigger {
  @override
  bool reviewHostReady() => widget.hostReady.value;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: widget.loaded,
    builder: (context, loaded, _) {
      if (loaded) maybeScheduleReviewPrompt();
      return Text(loaded ? 'feed' : 'loading');
    },
  );
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;
  late FakeReviewLauncher launcher;
  late ValueNotifier<bool> loaded;
  late ValueNotifier<bool> hostReady;

  setUp(() async {
    ArulDeepLink.reset();
    SharedPreferences.setMockInitialValues(<String, Object>{
      // Armed by an EARLIER process.
      ReviewLedger.armedLaunchKey: 'earlier',
      ReviewLedger.armedTriggerKey: 'ringtone',
    });
    prefs = await SharedPreferences.getInstance();
    launcher = FakeReviewLauncher();
    loaded = ValueNotifier(false);
    hostReady = ValueNotifier(true);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  tearDown(() {
    ArulDeepLink.reset();
    UpdateHolds.launch.value = UpdateLaunch.clear;
  });

  final shellNavKey = GlobalKey<NavigatorState>();

  /// Root navigator -> nested branch navigator -> the home screen, as the dock shell nests it.
  Future<void> pumpApp(WidgetTester tester) => tester.pumpWidget(
    ProviderScope(
      overrides: [
        reviewLedgerProvider.overrideWithValue(
          ReviewLedger(prefs, launchId: 'now'),
        ),
        reviewLauncherProvider.overrideWithValue(launcher),
        analyticsServiceProvider.overrideWithValue(RecordingAnalytics()),
      ],
      child: MaterialApp(
        home: Navigator(
          key: shellNavKey,
          onGenerateRoute: (_) => MaterialPageRoute<void>(
            builder: (_) => _Home(loaded: loaded, hostReady: hostReady),
          ),
        ),
      ),
    ),
  );

  Future<void> settle(WidgetTester tester) async {
    await tester.pump(reviewSettleDelay);
    await tester.pump();
    await tester.pump();
  }

  bool stillArmed() => prefs.getString(ReviewLedger.armedLaunchKey) != null;

  testWidgets('fires only after the feed has loaded, then after the settle', (
    tester,
  ) async {
    await pumpApp(tester);
    await settle(tester);
    expect(launcher.requests, 0, reason: 'still loading');

    loaded.value = true;
    await tester.pump();
    await tester.pump(reviewSettleDelay - const Duration(milliseconds: 1));
    expect(launcher.requests, 0, reason: 'inside the settle window');

    await settle(tester);
    expect(launcher.requests, 1);
    expect(stillArmed(), isFalse);
  });

  testWidgets('a sheet on the branch navigator skips and keeps it pending', (
    tester,
  ) async {
    await pumpApp(tester);
    loaded.value = true;
    await tester.pump();
    unawaited(
      showModalBottomSheet<void>(
        context: shellNavKey.currentContext!,
        builder: (_) => const SizedBox(height: 80),
      ),
    );
    await settle(tester);
    expect(launcher.requests, 0);
    expect(stillArmed(), isTrue);
  });

  testWidgets('a dialog on the root navigator skips and keeps it pending', (
    tester,
  ) async {
    await pumpApp(tester);
    loaded.value = true;
    await tester.pump();
    unawaited(
      showDialog<void>(
        context: shellNavKey.currentContext!,
        builder: (_) => const AlertDialog(content: Text('x')),
      ),
    );
    await settle(tester);
    expect(launcher.requests, 0);
    expect(stillArmed(), isTrue);
  });

  testWidgets('a pushed route (paywall, policy) skips', (tester) async {
    await pumpApp(tester);
    loaded.value = true;
    await tester.pump();
    unawaited(
      shellNavKey.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => const Text('premium')),
      ),
    );
    await settle(tester);
    expect(launcher.requests, 0);
    expect(stillArmed(), isTrue);
  });

  testWidgets('a link or push landing this launch skips', (tester) async {
    ArulDeepLink.requestTarget(const WallpaperLinkTarget('w1'));
    ArulDeepLink.consumeWallpaper();
    await pumpApp(tester);
    loaded.value = true;
    await tester.pump();
    await settle(tester);
    expect(launcher.requests, 0);
    expect(stillArmed(), isTrue);
  });

  testWidgets('a push with no parked target is a landing too', (tester) async {
    ArulDeepLink.noteExternalOpen();
    await pumpApp(tester);
    loaded.value = true;
    await tester.pump();
    await settle(tester);
    expect(launcher.requests, 0);
  });

  testWidgets('the app not in the foreground skips', (tester) async {
    await pumpApp(tester);
    loaded.value = true;
    await tester.pump();
    // An OS permission dialog or chooser over the Activity.
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await settle(tester);
    expect(launcher.requests, 0);
    expect(stillArmed(), isTrue);
  });

  testWidgets('the host saying "busy" skips', (tester) async {
    hostReady.value = false;
    await pumpApp(tester);
    loaded.value = true;
    await tester.pump();
    await settle(tester);
    expect(launcher.requests, 0);
    expect(stillArmed(), isTrue);
  });

  testWidgets('unmounted before the settle -> nothing', (tester) async {
    await pumpApp(tester);
    loaded.value = true;
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    await settle(tester);
    expect(launcher.requests, 0);
  });

  testWidgets('waits for the update check, then asks once it found nothing', (
    tester,
  ) async {
    UpdateHolds.launch.value = UpdateLaunch.undecided;
    await pumpApp(tester);
    loaded.value = true;
    await tester.pump();
    await settle(tester);
    await settle(tester);
    expect(launcher.requests, 0, reason: 'update still undecided');

    UpdateHolds.launch.value = UpdateLaunch.clear;
    await tester.pump();
    await tester.pump();
    expect(launcher.requests, 1);
  });

  testWidgets('an update prompt this launch wins: no review, the arm kept', (
    tester,
  ) async {
    UpdateHolds.launch.value = UpdateLaunch.undecided;
    await pumpApp(tester);
    loaded.value = true;
    await tester.pump();
    await settle(tester);

    UpdateHolds.launch.value = UpdateLaunch.prompted;
    await settle(tester);
    expect(launcher.requests, 0);
    expect(stillArmed(), isTrue);
  });
}
