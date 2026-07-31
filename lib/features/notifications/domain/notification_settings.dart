import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// User preferences for local notifications. Persisted as a single JSON blob in
/// [SharedPreferences] so it loads synchronously at startup, the same way theme
/// and locale do.
///
/// Deliberately minimal: one master opt-in plus one reminder time. There are NO
/// per-festival or per-category toggles — accepting notifications turns on the
/// whole set (the weekly devotional day + every festival). A settings screen
/// with sixteen switches is a settings screen nobody finishes reading.
///
/// Time is stored as plain hour/minute ints rather than a `TimeOfDay` so the
/// model stays context-free: the scheduler reads it well away from the widget
/// tree.
@immutable
class NotificationSettings {
  const NotificationSettings({
    this.masterEnabled = false,
    this.reminderHour = 8,
    this.reminderMinute = 0,
  });

  /// Master switch. Nothing is scheduled while this is off. Defaults to OFF —
  /// the user opts in, and opting in enables every reminder.
  final bool masterEnabled;

  /// The time of day every reminder fires — the weekly one, and the festival
  /// ones on their lead day.
  ///
  /// 08:00 rather than Pakiza's 09:00: the devotional habits these reminders sit
  /// alongside (lighting a lamp, a temple visit) belong to the early morning.
  final int reminderHour;
  final int reminderMinute;

  /// Namespaced `arul_*` per CLAUDE.md §0 — the storage keys are one of the
  /// deliberate deltas from Pakiza and must never be synced across.
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
