import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/analytics/analytics_provider.dart';
import '../../../core/analytics/analytics_service.dart';
import '../../../core/crash/crash_provider.dart';
import '../../../core/crash/crash_reporter.dart';
import '../../../core/providers/shared_preferences_provider.dart';
import '../data/review_launcher.dart';
import '../domain/review_ledger.dart';

enum ReviewAskOutcome {
  alreadyEvaluated,
  notArmed,
  capped,
  blocked,
  unavailable,
  failed,
  requested,
}

/// Asks Play for its review sheet at most once per process, and only when a success is pending.
///
/// Play reports neither whether the sheet showed nor whether a rating was left, so a completed
/// call is the only fact there is: it consumes the arm and counts against the cap either way.
class ReviewPromptController {
  ReviewPromptController({
    required this._ledger,
    required this._launcher,
    required this._analytics,
    required this._crash,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final ReviewLedger _ledger;
  final ReviewLauncher _launcher;
  final AnalyticsService _analytics;
  final CrashReporter _crash;
  final DateTime Function() _clock;

  bool _evaluated = false;

  /// [surfaceClear] is re-read after the availability round trip: a sheet or a permission dialog
  /// can arrive while Play answers, and a skip keeps the arm for the next cold open.
  Future<ReviewAskOutcome> maybeAsk(bool Function() surfaceClear) async {
    if (_evaluated) return ReviewAskOutcome.alreadyEvaluated;
    _evaluated = true;
    try {
      if (!_ledger.armedBeforeThisLaunch) return ReviewAskOutcome.notArmed;
      if (_ledger.capReached(_clock())) return ReviewAskOutcome.capped;
      if (!surfaceClear()) return ReviewAskOutcome.blocked;
      if (!await _launcher.isAvailable()) return ReviewAskOutcome.unavailable;
      if (!surfaceClear()) return ReviewAskOutcome.blocked;

      final trigger = _ledger.armedTrigger;
      final now = _clock();
      // Stamped BEFORE the call: a process that dies inside Play's sheet must still count.
      final undo = await _ledger.consume(now);
      try {
        await _launcher.requestReview();
      } on PlatformException catch (e) {
        // Play refused the flow (no Play Store, no Activity) -> nothing was asked -> keep the arm.
        await _ledger.restore(undo, now);
        _crash.log('review flow refused: ${e.code} ${e.message}');
        return ReviewAskOutcome.failed;
      }
      _analytics.track(
        'review_prompt_requested',
        properties: {
          'trigger': trigger?.key ?? 'unknown',
          'requests_30d': _ledger.requestsWithin(now).toString(),
        },
      );
      return ReviewAskOutcome.requested;
    } catch (error, stack) {
      debugPrint('[Review] ask failed: $error');
      _crash.recordError(error, stack, reason: 'review prompt');
      return ReviewAskOutcome.failed;
    }
  }
}

final reviewClockProvider = Provider<DateTime Function()>(
  (ref) => DateTime.now,
);

final reviewLauncherProvider = Provider<ReviewLauncher>(
  (ref) => const PlayReviewLauncher(),
);

final reviewLedgerProvider = Provider<ReviewLedger>(
  (ref) => ReviewLedger(ref.watch(sharedPreferencesProvider)),
);

final reviewPromptControllerProvider = Provider<ReviewPromptController>(
  (ref) => ReviewPromptController(
    ledger: ref.watch(reviewLedgerProvider),
    launcher: ref.watch(reviewLauncherProvider),
    analytics: ref.watch(analyticsServiceProvider),
    crash: ref.watch(crashReporterProvider),
    clock: ref.watch(reviewClockProvider),
  ),
);

/// Arms the next cold open's ask. Called after a set that already succeeded, so it can never fail
/// one: a missing or broken prefs store costs the ask, nothing else.
void armReviewPrompt(Ref ref, ReviewTrigger trigger) {
  try {
    unawaited(
      ref
          .read(reviewLedgerProvider)
          .arm(trigger)
          .catchError((Object e) => debugPrint('[Review] arm failed: $e')),
    );
  } catch (e) {
    debugPrint('[Review] arm unavailable: $e');
  }
}
