import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import '../perf/boot_trace.dart';

/// The session's copy in Google's Block Store (docs/auth.md §Session): it outlives an uninstall on
/// the same phone and moves on a device restore. Every failure is silent — the wall is the fallback.
abstract final class SessionBackup {
  static const _channel = MethodChannel('com.hsrutility.arul/session_backup');

  /// Off only in timing builds: the harness clears app data between sign-ins, and Block Store
  /// outlives a clear, so a restore would skip the very sheet being measured.
  static const restoreEnabled = bool.fromEnvironment(
    'SESSION_RESTORE',
    defaultValue: true,
  );

  static Future<void> save({
    required String accessToken,
    required String refreshToken,
    Map<String, String> profile = const {},
  }) async {
    try {
      await _channel.invokeMethod<bool>('save', {
        'json': jsonEncode({'a': accessToken, 'r': refreshToken, ...profile}),
      });
    } catch (_) {
      // No Play services, or a phone without Block Store.
    }
  }

  static Future<void> clear() async {
    try {
      await _channel.invokeMethod<bool>('clear');
    } catch (_) {}
  }

  /// The saved session, or null when there is none, it is unreadable, or Play services did not
  /// answer within [cap] — a fresh install's sheet waits on this, so the cap is the whole cost.
  static Future<Map<String, String>?> read({required Duration cap}) async {
    if (!restoreEnabled) return null;
    BootTrace.mark('sessionBackup: read start');
    try {
      final raw = await _channel.invokeMethod<String>('read').timeout(cap);
      BootTrace.mark('sessionBackup: read ${raw == null ? 'empty' : 'found'}');
      if (raw == null || raw.isEmpty) return null;
      final map = (jsonDecode(raw) as Map).cast<String, Object?>();
      final out = {
        for (final MapEntry(:key, :value) in map.entries)
          if (value is String && value.isNotEmpty) key: value,
      };
      return out['a'] != null && out['r'] != null ? out : null;
    } catch (e) {
      BootTrace.mark('sessionBackup: read gave up ($e)');
      return null;
    }
  }
}
