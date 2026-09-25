import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

String appLanguageName(String code) =>
    appLanguageNames[code] ?? appLanguageNames['en']!;

String appLanguageNativeName(String code) =>
    appLanguageNativeNames[code] ?? appLanguageNativeNames['en']!;

String? appLanguageCodeFor(String englishName) {
  for (final e in appLanguageNames.entries) {
    if (e.value == englishName) return e.key;
  }
  return null;
}

const appLocalePrefsKey = LocaleNotifier._key;

/// Who wrote [appLocalePrefsKey]: `pick` (Settings, the wall chip) or `link` (`lang=`).
/// Absent on a pick stored before this key existed -> read as `pick`.
const appLocaleSourcePrefsKey = 'arul_locale_source';

/// Set on a FRESH install's first process, cleared when `GET /geo` answers -> an update never sets it.
const geoPendingPrefsKey = 'arul_geo_pending';

/// The region's language as `GET /geo` answered it: a shipped code or [geoNone]. A hint, never a pick.
const geoLangPrefsKey = 'arul_geo_lang';

/// The region Cloudflare reported, raw, or [geoNone] -> `geo_region` on every event.
const geoRegionPrefsKey = 'arul_geo_region';

const geoNone = 'none';

/// Where the app's language came from -> `language_source` on every event.
/// `default` is a Dart keyword -> the English fallback is [fallback], reported as `default`.
enum LanguageSource {
  pick('pick'),
  link('link'),
  geo('geo'),
  phone('phone'),
  fallback('default');

  const LanguageSource(this.key);

  final String key;
}

/// [LocaleNotifier]'s resolution, callable before Riverpod exists — `main()` stamps it on
/// `Application Installed`, which fires ahead of the first frame.
/// An explicit pick or link -> the REGION (fresh installs, once) -> the phone -> English.
Locale resolveAppLocale(
  String? storedCode,
  String? geoCode,
  List<Locale> phoneLocales,
) {
  // A stored code the app no longer ships reads as English, never as the phone.
  if (storedCode != null) return _shipped(storedCode) ?? const Locale('en');
  return _shipped(geoCode) ?? _phoneLocale(phoneLocales) ?? const Locale('en');
}

LanguageSource resolveLanguageSource(
  String? storedCode,
  String? storedSource,
  String? geoCode,
  List<Locale> phoneLocales,
) {
  if (storedCode != null) {
    return storedSource == LanguageSource.link.key
        ? LanguageSource.link
        : LanguageSource.pick;
  }
  if (_shipped(geoCode) != null) return LanguageSource.geo;
  if (_phoneLocale(phoneLocales) != null) return LanguageSource.phone;
  return LanguageSource.fallback;
}

/// The shipped locale for [code], or null -> [geoNone] and anything unshipped read as no answer.
Locale? _shipped(String? code) {
  for (final supported in supportedAppLocales) {
    if (supported.languageCode == code) return supported;
  }
  return null;
}

/// Language only — a phone set to `ta-MY` or `hi-Latn` still reads Tamil and Hindi.
Locale? _phoneLocale(List<Locale> phoneLocales) {
  for (final phone in phoneLocales) {
    final shipped = _shipped(phone.languageCode);
    if (shipped != null) return shipped;
  }
  return null;
}

/// `language_source` and `geo_region` — the two registered properties that measure the region default.
typedef LanguageOrigin = ({LanguageSource source, String geoRegion});

/// [languageOriginProvider]'s value straight from prefs -> `main()` primes PostHog before Riverpod.
LanguageOrigin resolveLanguageOrigin(
  SharedPreferences prefs,
  List<Locale> phoneLocales,
) => (
  source: resolveLanguageSource(
    prefs.getString(appLocalePrefsKey),
    prefs.getString(appLocaleSourcePrefsKey),
    prefs.getString(geoLangPrefsKey),
    phoneLocales,
  ),
  geoRegion: geoRegionValue(prefs.getString(geoRegionPrefsKey)),
);

/// The stored region as a property value -> [geoNone] when unset, cut to GA4's 36-char limit.
String geoRegionValue(String? stored) {
  if (stored == null || stored.isEmpty) return geoNone;
  return stored.length > 36 ? stored.substring(0, 36) : stored;
}

/// The phone's own language preference order.
///
/// A provider so tests can hand in a phone; read straight off the [ui.PlatformDispatcher] rather
/// than `WidgetsBinding.instance`, which is not up in a plain `ProviderContainer` test.
@Riverpod(keepAlive: true)
List<Locale> platformLocales(Ref ref) => ui.PlatformDispatcher.instance.locales;

/// The app locale. Persisted pick first, then the REGION, then the PHONE, then English.
///
/// A Tamil phone that opened Arul in English had to be told, in English, where the language picker
/// was — the one screen that matters (sign-in) is the one screen it was hardest on. So an unset
/// preference follows the phone.
///
/// **The phone fallback is never PERSISTED.** Writing it would freeze the app to whatever the phone
/// said on first launch, so changing the phone's language later would stop moving the app; and
/// Settings would show a language the user never picked as if they had. Only an explicit pick
/// writes — Settings, the sign-in trigger, or a `lang=` deep link (which persists deliberately, so
/// the link's language wins over a later phone change too). The region answer is stored beside
/// the pick, never as one, for the same reason.
@Riverpod(keepAlive: true)
class LocaleNotifier extends _$LocaleNotifier {
  static const _key = 'arul_locale';

  @override
  Locale build() {
    final prefs = ref.read(sharedPreferencesProvider);
    return resolveAppLocale(
      prefs.getString(_key),
      prefs.getString(geoLangPrefsKey),
      ref.read(platformLocalesProvider),
    );
  }

  /// An explicit choice -> [source] is `pick` (Settings, the wall chip) or `link` (`lang=`).
  Future<void> setLocale(
    Locale locale, {
    required LanguageSource source,
  }) async {
    assert(
      source == LanguageSource.pick || source == LanguageSource.link,
      'only a pick or a link is written to $_key',
    );
    final prefs = ref.read(sharedPreferencesProvider);
    state = locale;
    final writes = [
      prefs.setString(_key, locale.languageCode),
      prefs.setString(appLocaleSourcePrefsKey, source.key),
    ];
    // Prefs caches synchronously -> the origin re-reads the new source even when the language held.
    ref.invalidate(languageOriginProvider);
    await Future.wait(writes);
  }

  /// A fresh install's `GET /geo` answer -> stored once, pending cleared, applied live unless a
  /// pick or a link already exists. Never written to [_key]: the region is a hint like the phone.
  Future<void> setGeoHint({String? lang, String? region}) async {
    final prefs = ref.read(sharedPreferencesProvider);
    // Only a SHIPPED code is kept -> a code a later build adds cannot re-language this install then.
    final geo = _shipped(lang);
    final writes = [
      prefs.setString(geoLangPrefsKey, geo?.languageCode ?? geoNone),
      prefs.setString(
        geoRegionPrefsKey,
        region == null || region.isEmpty ? geoNone : region,
      ),
      prefs.remove(geoPendingPrefsKey),
    ];
    if (geo != null && prefs.getString(_key) == null) state = geo;
    ref.invalidate(languageOriginProvider);
    await Future.wait(writes);
  }
}

/// Where the language came from, re-read from prefs -> [LocaleNotifier] invalidates it on every write.
/// Never derived from [localeProvider]: a Tamil phone answered `ta` by its region changes the SOURCE
/// only, and an equal locale never notifies.
@Riverpod(keepAlive: true)
LanguageOrigin languageOrigin(Ref ref) => resolveLanguageOrigin(
  ref.read(sharedPreferencesProvider),
  ref.read(platformLocalesProvider),
);
