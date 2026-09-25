// Play's review sheet: asked on a LATER cold open than the success that armed it, once per process,
// at most 7 times in any rolling 30 days, and never at the cost of an exception reaching the UI.
// Play never says whether the sheet showed, so a completed call is what consumes the arm.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:arul/core/crash/crash_reporter.dart';
import 'package:arul/features/review/data/review_launcher.dart';
import 'package:arul/features/review/domain/review_ledger.dart';
import 'package:arul/features/review/providers/review_prompt_controller.dart';

import 'review_fakes.dart';

void main() {
  late SharedPreferences prefs;
  late FakeReviewLauncher launcher;
  late RecordingAnalytics analytics;
  late DateTime now;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    prefs = await SharedPreferences.getInstance();
    launcher = FakeReviewLauncher();
    analytics = RecordingAnalytics();
    now = DateTime(2030, 1, 1, 9);
  });

  ReviewLedger ledgerFor(String launch) =>
      ReviewLedger(prefs, launchId: launch);

  /// A fresh process: new launch id, new controller.
  ReviewPromptController coldOpen(String launch, {CrashReporter? crash}) =>
      ReviewPromptController(
        ledger: ledgerFor(launch),
        launcher: launcher,
        analytics: analytics,
        crash: crash ?? const NoOpCrashReporter(),
        clock: () => now,
      );

  bool clear() => true;

  test('the launch that armed never asks — the next cold open does', () async {
    await ledgerFor('A').arm(ReviewTrigger.wallpaperStatic);

    expect(await coldOpen('A').maybeAsk(clear), ReviewAskOutcome.notArmed);
    expect(launcher.requests, 0);

    expect(await coldOpen('B').maybeAsk(clear), ReviewAskOutcome.requested);
    expect(launcher.requests, 1);
    expect(ledgerFor('B').isArmed, isFalse, reason: 'the ask consumes it');
    expect(analytics.props['review_prompt_requested'], {
      'trigger': 'wallpaper_static',
      'requests_30d': '1',
    });
  });

  test('once per process: a second call in the same launch is inert', () async {
    await ledgerFor('A').arm(ReviewTrigger.ringtone);
    final controller = coldOpen('B');
    expect(await controller.maybeAsk(() => false), ReviewAskOutcome.blocked);
    expect(await controller.maybeAsk(clear), ReviewAskOutcome.alreadyEvaluated);
    expect(launcher.requests, 0);
  });

  test('not armed -> nothing, not even the availability round trip', () async {
    expect(await coldOpen('B').maybeAsk(clear), ReviewAskOutcome.notArmed);
    expect(launcher.availabilityChecks, 0);
  });

  group('blocked surface keeps the ask pending', () {
    test('blocked before the round trip', () async {
      await ledgerFor('A').arm(ReviewTrigger.wallpaperLive);
      expect(
        await coldOpen('B').maybeAsk(() => false),
        ReviewAskOutcome.blocked,
      );
      expect(launcher.requests, 0);
      expect(ledgerFor('C').armedBeforeThisLaunch, isTrue);
      expect(await coldOpen('C').maybeAsk(clear), ReviewAskOutcome.requested);
    });

    test('blocked by something that arrived during the round trip', () async {
      await ledgerFor('A').arm(ReviewTrigger.wallpaperLive);
      var checks = 0;
      final outcome = await coldOpen('B').maybeAsk(() => ++checks == 1);
      expect(outcome, ReviewAskOutcome.blocked);
      expect(launcher.requests, 0);
      expect(ledgerFor('C').isArmed, isTrue);
    });
  });

  group('unavailable never throws and keeps the ask', () {
    test('isAvailable false', () async {
      launcher.available = false;
      await ledgerFor('A').arm(ReviewTrigger.ringtone);
      expect(await coldOpen('B').maybeAsk(clear), ReviewAskOutcome.unavailable);
      expect(launcher.requests, 0);
      expect(ledgerFor('C').isArmed, isTrue);
    });

    test(
      'requestReview refused by Play -> arm and cap slot restored',
      () async {
        launcher.requestError = PlatformException(
          code: 'error',
          message: 'In-App Review API unavailable',
        );
        await ledgerFor('A').arm(ReviewTrigger.ringtone);
        expect(await coldOpen('B').maybeAsk(clear), ReviewAskOutcome.failed);
        expect(ledgerFor('C').armedBeforeThisLaunch, isTrue);
        expect(ledgerFor('C').armedTrigger, ReviewTrigger.ringtone);
        expect(ledgerFor('C').requestsWithin(now), 0);
        expect(analytics.events, isEmpty);
      },
    );

    test('an unexpected error is recorded non-fatal, never rethrown', () async {
      launcher.availabilityError = StateError('channel gone');
      final crash = RecordingCrash();
      await ledgerFor('A').arm(ReviewTrigger.ringtone);
      expect(
        await coldOpen('B', crash: crash).maybeAsk(clear),
        ReviewAskOutcome.failed,
      );
      expect(crash.errors, hasLength(1));
      expect(crash.fatal, [false]);
    });
  });

  test(
    '7 asks in any rolling 30 days, then capped until the oldest ages out',
    () async {
      final start = now;
      for (var i = 0; i < 7; i++) {
        now = start.add(Duration(days: i * 4));
        await ledgerFor('arm$i').arm(ReviewTrigger.wallpaperStatic);
        expect(
          await coldOpen('open$i').maybeAsk(clear),
          ReviewAskOutcome.requested,
        );
      }
      expect(launcher.requests, 7);

      // Day 25: the 8th pending success is held, not consumed.
      now = start.add(const Duration(days: 25));
      await ledgerFor('arm7').arm(ReviewTrigger.ringtone);
      expect(await coldOpen('open7').maybeAsk(clear), ReviewAskOutcome.capped);
      expect(ledgerFor('x').isArmed, isTrue);

      // Day 29 still inside the first ask's window.
      now = start.add(const Duration(days: 29, hours: 23));
      expect(await coldOpen('open8').maybeAsk(clear), ReviewAskOutcome.capped);

      // Day 30: the first ask has aged out -> one slot opens.
      now = start.add(const Duration(days: 30));
      expect(
        await coldOpen('open9').maybeAsk(clear),
        ReviewAskOutcome.requested,
      );
      expect(launcher.requests, 8);
      expect(ledgerFor('x').requestsWithin(now), 7);
    },
  );

  test('the real launcher is the Play plugin', () {
    expect(const PlayReviewLauncher(), isA<ReviewLauncher>());
  });
}
