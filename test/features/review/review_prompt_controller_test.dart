// Play's review sheet: asked on a LATER cold open than the success that armed it, only once the
// person has 2 successes (any mix) with the first one 3+ days old, once per process, at most once
// in any rolling 120 days, and never at the cost of an exception reaching the UI.
// Play never says whether the sheet showed, so a completed call is what consumes the arm.

import 'package:arul/core/crash/crash_reporter.dart';
import 'package:arul/features/review/data/review_launcher.dart';
import 'package:arul/features/review/domain/review_ledger.dart';
import 'package:arul/features/review/providers/review_prompt_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'review_fakes.dart';

void main() {
  late SharedPreferences prefs;
  late FakeReviewLauncher launcher;
  late RecordingAnalytics analytics;
  late DateTime now;

  // Engaged by default (3 earlier successes, the first a month back) so each test isolates one gate;
  // the engagement gate has its own group, which starts from nothing.
  Future<void> seed(Map<String, Object> values) async {
    SharedPreferences.setMockInitialValues(values);
    prefs = await SharedPreferences.getInstance();
  }

  setUp(() async {
    now = DateTime(2030, 1, 1, 9);
    await seed(<String, Object>{
      ReviewLedger.successesKey: 3,
      ReviewLedger.firstSuccessKey: DateTime(
        2029,
        12,
        1,
      ).millisecondsSinceEpoch,
    });
    launcher = FakeReviewLauncher();
    analytics = RecordingAnalytics();
  });

  ReviewLedger ledgerFor(String launch) =>
      ReviewLedger(prefs, launchId: launch, clock: () => now);

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
      'requests_120d': '1',
      'successes': '4',
    });
  });

  group('engagement gate: 2 successes, the first 3+ days old', () {
    setUp(() => seed(<String, Object>{}));

    test('a first-day user is never asked, and the arm waits', () async {
      await ledgerFor('A').arm(ReviewTrigger.wallpaperStatic);
      await ledgerFor('A').arm(ReviewTrigger.ringtone);
      expect(ledgerFor('B').successes, 2);

      now = now.add(const Duration(days: 2, hours: 23));
      expect(await coldOpen('B').maybeAsk(clear), ReviewAskOutcome.tooEarly);
      expect(launcher.availabilityChecks, 0);
      expect(ledgerFor('C').armedBeforeThisLaunch, isTrue);

      now = now.add(const Duration(hours: 1));
      expect(await coldOpen('C').maybeAsk(clear), ReviewAskOutcome.requested);
    });

    test('days of use but one success -> still waits', () async {
      await ledgerFor('A').arm(ReviewTrigger.wallpaperLive);
      now = now.add(const Duration(days: 5));
      expect(await coldOpen('B').maybeAsk(clear), ReviewAskOutcome.tooEarly);
    });

    test('any mix counts: one wallpaper and one ringtone qualify', () async {
      await ledgerFor('A').arm(ReviewTrigger.wallpaperStatic);
      now = now.add(const Duration(days: 3));
      await ledgerFor('B').arm(ReviewTrigger.ringtone);
      expect(await coldOpen('C').maybeAsk(clear), ReviewAskOutcome.requested);
    });

    test('the first success is stamped once, never moved later', () async {
      final start = now;
      await ledgerFor('A').arm(ReviewTrigger.ringtone);
      now = start.add(const Duration(days: 10));
      await ledgerFor('B').arm(ReviewTrigger.ringtone);
      expect(
        prefs.getInt(ReviewLedger.firstSuccessKey),
        start.millisecondsSinceEpoch,
      );
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
    'one ask in any rolling 120 days, then capped until it ages out',
    () async {
      final start = now;
      await ledgerFor('arm0').arm(ReviewTrigger.wallpaperStatic);
      expect(
        await coldOpen('open0').maybeAsk(clear),
        ReviewAskOutcome.requested,
      );
      expect(launcher.requests, 1);

      // Day 1: the next pending success is held, not consumed.
      now = start.add(const Duration(days: 1));
      await ledgerFor('arm1').arm(ReviewTrigger.ringtone);
      expect(await coldOpen('open1').maybeAsk(clear), ReviewAskOutcome.capped);
      expect(ledgerFor('x').isArmed, isTrue);

      // Day 30 — the old cap would have asked here; day 119 is still inside the window.
      now = start.add(const Duration(days: 30));
      expect(await coldOpen('open2').maybeAsk(clear), ReviewAskOutcome.capped);
      now = start.add(const Duration(days: 119, hours: 23));
      expect(await coldOpen('open2b').maybeAsk(clear), ReviewAskOutcome.capped);
      expect(launcher.requests, 1);

      // Day 120: the first ask has aged out -> the held success is asked.
      now = start.add(const Duration(days: 120));
      expect(
        await coldOpen('open3').maybeAsk(clear),
        ReviewAskOutcome.requested,
      );
      expect(launcher.requests, 2);
      expect(ledgerFor('x').requestsWithin(now), 1);
      expect(analytics.props['review_prompt_requested'], {
        'trigger': 'ringtone',
        'requests_120d': '1',
        'successes': '5',
      });

      // Day 121: that ask opens a fresh window -> capped again.
      now = start.add(const Duration(days: 121));
      await ledgerFor('arm2').arm(ReviewTrigger.wallpaperLive);
      expect(await coldOpen('open4').maybeAsk(clear), ReviewAskOutcome.capped);
      expect(launcher.requests, 2);
    },
  );

  test('the real launcher is the Play plugin', () {
    expect(const PlayReviewLauncher(), isA<ReviewLauncher>());
  });
}
