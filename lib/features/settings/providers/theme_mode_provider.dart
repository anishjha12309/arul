import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/shared_preferences_provider.dart';

/// Theme mode, persisted. Light / Dark / System — and NEVER seeded from the
/// device wallpaper: an app whose content is wallpapers must not recolour itself
/// from whichever one the user last applied (CLAUDE.md §7).
final themeModeProvider = NotifierProvider<ThemeModeNotifier, ThemeMode>(
  ThemeModeNotifier.new,
);

class ThemeModeNotifier extends Notifier<ThemeMode> {
  static const _key = 'arul_theme_mode';

  /// Read synchronously, exactly like the locale notifier next door.
  ///
  /// This used to return `ThemeMode.system` and restore asynchronously, which
  /// meant a user with Light saved on a dark device got a dark first frame and
  /// then a snap to light on every cold start. `main()` already resolves the
  /// prefs handle before `runApp` and overrides `sharedPreferencesProvider` with
  /// it, so there is nothing to wait for — the first frame can just be right.
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
