import 'package:shared_preferences/shared_preferences.dart';

/// The IST calendar day of [t] as `yyyy-MM-dd`. India keeps no DST, so a fixed +5:30 is exact.
String istDay(DateTime t) {
  final ist = t.toUtc().add(const Duration(hours: 5, minutes: 30));
  String two(int n) => n.toString().padLeft(2, '0');
  return '${ist.year}-${two(ist.month)}-${two(ist.day)}';
}

/// How often the ₹99 win-back sheet may open by itself, remembered on this phone only. It never
/// decides who is offered ₹99 — that is the Worker's verdict ([docs/winback-reach.md]).
class WinbackLedger {
  WinbackLedger(this._prefs, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  static const shownDayKey = 'arul_winback_shown_day';
  static const dismissalsKey = 'arul_winback_daily_dismissals';
  static const pausedUntilKey = 'arul_winback_paused_until';

  /// The daily sheet left this many times in a row rests for [pause] (owner).
  static const dismissalsToPause = 2;
  static const pause = Duration(days: 7);

  final SharedPreferences _prefs;
  final DateTime Function() _clock;

  /// `yyyy-MM-dd` sorts as dates do, so a clock set backwards only makes the wait longer.
  bool canAutoShow() {
    final today = istDay(_clock());
    final shown = _prefs.getString(shownDayKey);
    if (shown != null && today.compareTo(shown) <= 0) return false;
    final pausedUntil = _prefs.getString(pausedUntilKey);
    return pausedUntil == null || today.compareTo(pausedUntil) > 0;
  }

  /// Any ₹99 win-back sheet, from any door, is that day's sheet.
  Future<void> noteShown() => _prefs.setString(shownDayKey, istDay(_clock()));

  /// The daily sheet closed without a purchase; the last of [dismissalsToPause] starts the pause.
  Future<void> noteDailyDismissed() async {
    final count = (_prefs.getInt(dismissalsKey) ?? 0) + 1;
    if (count < dismissalsToPause) {
      await _prefs.setInt(dismissalsKey, count);
      return;
    }
    await _prefs.setString(pausedUntilKey, istDay(_clock().add(pause)));
    await _prefs.remove(dismissalsKey);
  }

  Future<void> noteAccepted() => _prefs.remove(dismissalsKey);
}
