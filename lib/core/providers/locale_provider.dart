import 'package:flutter/material.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'shared_preferences_provider.dart';

part 'locale_provider.g.dart';

/// All supported app locales in display order (matches l10n.yaml).
const supportedAppLocales = <Locale>[
  Locale('en'),
  Locale('ta'),
  Locale('te'),
  Locale('kn'),
  Locale('ml'),
  Locale('hi'),
];

/// Persisted app locale; defaults to English when unset or unsupported.
@Riverpod(keepAlive: true)
class LocaleNotifier extends _$LocaleNotifier {
  static const _key = 'arul_locale';

  @override
  Locale build() {
    final code = ref.read(sharedPreferencesProvider).getString(_key);
    if (code == null) return const Locale('en');
    return supportedAppLocales.firstWhere(
      (l) => l.languageCode == code,
      orElse: () => const Locale('en'),
    );
  }

  Future<void> setLocale(Locale locale) async {
    state = locale;
    await ref
        .read(sharedPreferencesProvider)
        .setString(_key, locale.languageCode);
  }
}
