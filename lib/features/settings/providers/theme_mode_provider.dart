import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/shared_preferences_provider.dart';

/// Theme mode, persisted: Light / Dark / System.
/// NEVER seeded from the device wallpaper — this app's content IS wallpapers (CLAUDE.md §7).
final themeModeProvider = NotifierProvider<ThemeModeNotifier, ThemeMode>(
  ThemeModeNotifier.new,
);

class ThemeModeNotifier extends Notifier<ThemeMode> {
  static const _key = 'arul_theme_mode';

  /// Read SYNCHRONOUSLY, exactly like the locale notifier next door.
  ///
  /// Restoring asynchronously gave a Light user on a dark device a dark first frame, then a snap.
  /// `main()` resolves the prefs handle before `runApp` -> there is nothing to wait for.
  @override
  ThemeMode build() {
    final saved = ref.read(sharedPreferencesProvider).getString(_key);
    if (saved == null) return ThemeMode.system;
    return ThemeMode.values.firstWhere(
      (m) => m.name == saved,
      orElse: () => ThemeMode.system,
    );
  }

  /// Applies [mode] immediately; the write is what the caller may await.
  Future<void> select(ThemeMode mode) async {
    state = mode;
    await ref.read(sharedPreferencesProvider).setString(_key, mode.name);
  }
}
