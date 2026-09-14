import 'dart:ui' as ui;

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

/// Locale code → the English name Settings shows and the language sheet returns.
///
/// ONE home for the mapping: Settings, the sheet and the sign-in trigger all read it. Two copies
/// drifted once already — the sheet returns a NAME, so a screen holding its own table silently
/// stops matching the moment either side is edited.
const appLanguageNames = <String, String>{
  'en': 'English',
  'ta': 'Tamil',
  'te': 'Telugu',
  'kn': 'Kannada',
  'ml': 'Malayalam',
  'hi': 'Hindi',
};

/// Locale code → the language's name in its OWN script — what a speaker scans a list for.
/// Never translated per UI language: हिन्दी is हिन्दी in the Tamil build too.
const appLanguageNativeNames = <String, String>{
  'en': 'English',
  'ta': 'தமிழ்',
  'te': 'తెలుగు',
  'kn': 'ಕನ್ನಡ',
  'ml': 'മലയാളം',
  'hi': 'हिन्दी',
};

/// The English name for [code], falling back to English for anything unsupported.
String appLanguageName(String code) =>
    appLanguageNames[code] ?? appLanguageNames['en']!;

/// The native name for [code], falling back to English for anything unsupported.
String appLanguageNativeName(String code) =>
    appLanguageNativeNames[code] ?? appLanguageNativeNames['en']!;

/// The locale code an English name from the sheet belongs to, or null.
String? appLanguageCodeFor(String englishName) {
  for (final e in appLanguageNames.entries) {
    if (e.value == englishName) return e.key;
  }
  return null;
}

/// The prefs key [LocaleNotifier] persists an explicit pick under.
const appLocalePrefsKey = LocaleNotifier._key;

/// [LocaleNotifier]'s resolution, callable before Riverpod exists — `main()` stamps it on
/// `Application Installed`, which fires ahead of the first frame.
Locale resolveAppLocale(String? storedCode, List<Locale> phoneLocales) {
  if (storedCode != null) {
    return supportedAppLocales.firstWhere(
      (l) => l.languageCode == storedCode,
      orElse: () => const Locale('en'),
    );
  }
  // Language only — a phone set to `ta-MY` or `hi-Latn` still reads Tamil and Hindi.
  for (final phone in phoneLocales) {
    for (final supported in supportedAppLocales) {
      if (supported.languageCode == phone.languageCode) return supported;
    }
  }
  return const Locale('en');
}

/// The phone's own language preference order.
///
/// A provider so tests can hand in a phone; read straight off the [ui.PlatformDispatcher] rather
/// than `WidgetsBinding.instance`, which is not up in a plain `ProviderContainer` test.
@Riverpod(keepAlive: true)
List<Locale> platformLocales(Ref ref) => ui.PlatformDispatcher.instance.locales;

/// The app locale. Persisted pick first, then the PHONE, then English.
///
/// A Tamil phone that opened Arul in English had to be told, in English, where the language picker
/// was — the one screen that matters (sign-in) is the one screen it was hardest on. So an unset
/// preference follows the phone.
///
/// **The phone fallback is never PERSISTED.** Writing it would freeze the app to whatever the phone
/// said on first launch, so changing the phone's language later would stop moving the app; and
/// Settings would show a language the user never picked as if they had. Only an explicit pick
/// writes — Settings, the sign-in trigger, or a `lang=` deep link (which persists deliberately, so
/// the link's language wins over a later phone change too).
@Riverpod(keepAlive: true)
class LocaleNotifier extends _$LocaleNotifier {
  static const _key = 'arul_locale';

  @override
  Locale build() => resolveAppLocale(
    ref.read(sharedPreferencesProvider).getString(_key),
    ref.read(platformLocalesProvider),
  );

  Future<void> setLocale(Locale locale) async {
    state = locale;
    await ref
        .read(sharedPreferencesProvider)
        .setString(_key, locale.languageCode);
  }
}
