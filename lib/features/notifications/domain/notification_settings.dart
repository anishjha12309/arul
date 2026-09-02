import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// User preferences for local notifications, one JSON blob in [SharedPreferences].
///
/// Loads synchronously at startup, the same way theme and locale do.
/// One master opt-in plus one reminder time — NO per-festival or per-category toggles.
/// Accepting notifications turns on the whole set; sixteen switches is a screen nobody reads.
/// The scheduler reads this well away from the widget tree -> plain ints, never a `TimeOfDay`.
@immutable
class NotificationSettings {
  const NotificationSettings({
    this.masterEnabled = false,
    this.reminderHour = 8,
    this.reminderMinute = 0,
  });

  /// Master switch — nothing is scheduled while it is off, and it defaults to OFF.
  /// The user opts in, and opting in enables every reminder.
  final bool masterEnabled;

  /// The time every reminder fires — the weekly one, and the festival ones on their lead day.
  ///
  /// 08:00: the habits these sit alongside — lighting a lamp, a temple visit — are early-morning.
  final int reminderHour;
  final int reminderMinute;

  /// Namespaced `arul_*` (CLAUDE.md §0) — a deliberate delta from Pakiza, never to be synced across.
  static const _prefsKey = 'arul_notification_settings';

  factory NotificationSettings.fromPrefs(SharedPreferences prefs) {
    final raw = prefs.getString(_prefsKey);
    if (raw == null) return const NotificationSettings();
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      return NotificationSettings(
        masterEnabled: j['masterEnabled'] as bool? ?? false,
        reminderHour: j['reminderHour'] as int? ?? 8,
        reminderMinute: j['reminderMinute'] as int? ?? 0,
      );
    } catch (_) {
      // Corrupt blob — fall back to defaults rather than crash on startup.
      return const NotificationSettings();
    }
  }

  Future<void> save(SharedPreferences prefs) => prefs.setString(
    _prefsKey,
    jsonEncode({
      'masterEnabled': masterEnabled,
      'reminderHour': reminderHour,
      'reminderMinute': reminderMinute,
    }),
  );

  NotificationSettings copyWith({
    bool? masterEnabled,
    int? reminderHour,
    int? reminderMinute,
  }) => NotificationSettings(
    masterEnabled: masterEnabled ?? this.masterEnabled,
    reminderHour: reminderHour ?? this.reminderHour,
    reminderMinute: reminderMinute ?? this.reminderMinute,
  );

  @override
  bool operator ==(Object other) =>
      other is NotificationSettings &&
      other.masterEnabled == masterEnabled &&
      other.reminderHour == reminderHour &&
      other.reminderMinute == reminderMinute;

  @override
  int get hashCode => Object.hash(masterEnabled, reminderHour, reminderMinute);
}
