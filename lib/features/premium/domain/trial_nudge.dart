import 'package:shared_preferences/shared_preferences.dart';

/// The record of a trial someone started and did not finish.
///
/// Only 12 in 100 trial-tappers ever make a second attempt, and second attempts convert at roughly
/// twice the rate of first ones. The intent flow's one toast is the only thing that ever mentions
/// the abandonment, and it is gone by the next screen — so the abandonment is written down instead,
/// and two things read it back: a dismissible row on the next open, and one reminder the same day.
///
/// Pure prefs arithmetic, no plugins and no Riverpod, so the rules below can be pinned in tests.
abstract final class TrialNudge {
  static const markerKey = 'arul_trial_unfinished_ms';

  /// The merchant order id it died on — kept so a late grant can be matched to it by hand.
  static const orderKey = 'arul_trial_unfinished_order';

  /// The instant the one reminder is due, epoch ms.
  ///
  /// Persisted rather than recomputed because [NotificationService.applySettings] cancels EVERY
  /// pending notification on each launch: the reminder has to be re-armed afterwards, and re-arming
  /// from "now" would walk it further away on every launch until the user never got it.
  static const reminderDueKey = 'arul_trial_reminder_due_ms';

  /// How long an unfinished trial is worth mentioning. Past this the moment has gone.
  static const window = Duration(days: 7);

  static const reminderDelay = Duration(hours: 6);
  static const reminderEarliestHour = 9;
  static const reminderLatestHour = 21;

  static Future<void> mark(
    SharedPreferences prefs, {
    required String orderId,
    required DateTime now,
    int? dueMs,
  }) async {
    await prefs.setInt(markerKey, now.millisecondsSinceEpoch);
    await prefs.setString(orderKey, orderId);
    if (dueMs == null) {
      await prefs.remove(reminderDueKey);
    } else {
      await prefs.setInt(reminderDueKey, dueMs);
    }
  }

  /// Forgets the unfinished attempt. Idempotent — the callers fire it on every settled outcome.
  static Future<void> clear(SharedPreferences prefs) async {
    await prefs.remove(markerKey);
    await prefs.remove(orderKey);
    await prefs.remove(reminderDueKey);
  }

  /// Whether the row should show. A marker older than [window] is not shown AND not cleared here —
  /// clearing is a write, and this is called from a build.
  static bool isLive(SharedPreferences prefs, DateTime now) {
    final at = prefs.getInt(markerKey);
    if (at == null) return false;
    final age = now.difference(DateTime.fromMillisecondsSinceEpoch(at));
    return !age.isNegative && age < window;
  }

  static DateTime? pendingReminder(SharedPreferences prefs, DateTime now) {
    final due = prefs.getInt(reminderDueKey);
    if (due == null) return null;
    final at = DateTime.fromMillisecondsSinceEpoch(due);
    return at.isAfter(now) ? at : null;
  }

  /// [reminderDelay] from [now], pulled into waking hours.
  ///
  /// A reminder about money that arrives at 03:00 is a reason to uninstall, not to finish a trial.
  /// Anything landing outside [reminderEarliestHour]–[reminderLatestHour] moves to the next
  /// [reminderEarliestHour] — the same morning when it fell before it, the next when it fell after.
  static DateTime reminderTime(DateTime now) {
    final t = now.add(reminderDelay);
    if (t.hour >= reminderEarliestHour && t.hour < reminderLatestHour) return t;
    var next = DateTime(t.year, t.month, t.day, reminderEarliestHour);
    if (!next.isAfter(t)) next = next.add(const Duration(days: 1));
    return next;
  }
}
