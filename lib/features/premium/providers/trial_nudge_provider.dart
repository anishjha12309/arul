import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../app/l10n/app_localizations.dart';
import '../../../core/providers/locale_provider.dart';
import '../../../core/providers/shared_preferences_provider.dart';
import '../../notifications/providers/notification_providers.dart';
import '../domain/trial_nudge.dart';

part 'trial_nudge_provider.g.dart';

/// Whether the "finish setting up your free trial" row should show.
///
/// keepAlive: a dismissal hides the row for the rest of the process, never for good — the marker
/// outlives it, so the next cold start asks again until the trial is finished or the marker ages
/// out. The provider is the only writer of [TrialNudge]'s keys, so the row, the reminder and the
/// prefs can never disagree about whether an unfinished trial exists.
@Riverpod(keepAlive: true)
class TrialNudgeNotifier extends _$TrialNudgeNotifier {
  @override
  bool build() =>
      TrialNudge.isLive(ref.read(sharedPreferencesProvider), DateTime.now());

  SharedPreferences get _prefs => ref.read(sharedPreferencesProvider);

  /// Records an abandoned setup and arms the one reminder.
  ///
  /// A no-op unless [trialAttempt]: the row and the reminder both say "free trial", which is a lie
  /// to someone who spent theirs and was abandoning a ₹199 charge.
  Future<void> remember(String orderId, {required bool trialAttempt}) async {
    if (!trialAttempt) return;
    final now = DateTime.now();
    final due = TrialNudge.reminderTime(now);

    // Permission is NEVER requested here — this fires from a payment failing, and the row covers
    // anyone who has not already opted in. `scheduleTrialReminder` answers false when it did not
    // arm, and the instant is persisted only when it did, so the launch re-arm stays honest.
    //
    // Best-effort, and the marker does not depend on it: the ROW is the half that works for
    // everyone, and a notification layer that is absent or refuses must not cost it.
    var armed = false;
    try {
      final l10n = lookupAppLocalizations(ref.read(localeProvider));
      armed = await ref
          .read(notificationServiceProvider)
          .scheduleTrialReminder(
            due: due,
            title: l10n.trialReminderTitle,
            body: l10n.trialReminderBody,
          );
    } catch (e) {
      debugPrint('[TrialNudge] reminder not armed: $e');
    }

    await TrialNudge.mark(
      _prefs,
      orderId: orderId,
      now: now,
      dueMs: armed ? due.millisecondsSinceEpoch : null,
    );
    state = true;
  }

  /// Hides the row for the rest of this process. The marker stays: they did not finish, they only
  /// declined to be asked right now.
  void dismiss() => state = false;

  /// The trial is finished, the user is premium, or the marker aged out — forget it entirely.
  /// Idempotent, and safe to call from a settled purchase that no screen is watching.
  Future<void> resolve() async {
    state = false;
    await TrialNudge.clear(_prefs);
    try {
      await ref.read(notificationServiceProvider).cancelTrialReminder();
    } catch (e) {
      // The marker is already gone, which is what the row reads. A reminder that cannot be
      // cancelled is a stale tap into a paywall the user has no reason to act on — not a failure
      // worth breaking a completed purchase over.
      debugPrint('[TrialNudge] reminder not cancelled: $e');
    }
  }
}
