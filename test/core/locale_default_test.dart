// The app's language when nobody has picked one.
//
// A Tamil phone that opened Arul in English had to be told, in English, where the picker was. So an
// unset preference follows the PHONE. The trap this pins is the other half: the phone fallback is
// never written down. Persisting it would freeze the app to whatever the phone said on first
// launch, and would show Settings a language the user never chose as if they had.

import 'package:arul/core/providers/locale_provider.dart';
import 'package:arul/core/providers/shared_preferences_provider.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<(ProviderContainer, SharedPreferences)> boot({
    String? persisted,
    List<Locale> phone = const [Locale('en')],
  }) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'arul_locale': ?persisted,
    });
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        platformLocalesProvider.overrideWithValue(phone),
      ],
    );
    addTearDown(container.dispose);
    return (container, prefs);
  }

  group('the phone decides when nothing is persisted', () {
    test('a Tamil phone opens the app in Tamil', () async {
      final (container, _) = await boot(phone: const [Locale('ta')]);
      expect(container.read(localeProvider), const Locale('ta'));
    });

    test('an unsupported phone language falls back to English', () async {
      final (container, _) = await boot(phone: const [Locale('fr')]);
      expect(container.read(localeProvider), const Locale('en'));
    });

    test(
      'the FIRST supported phone locale wins, not the first locale',
      () async {
        final (container, _) = await boot(
          phone: const [Locale('fr'), Locale('kn'), Locale('hi')],
        );
        expect(container.read(localeProvider), const Locale('kn'));
      },
    );

    test('region and script are ignored — only the language matters', () async {
      final (container, _) = await boot(
        phone: const [
          Locale.fromSubtags(languageCode: 'ta', countryCode: 'MY'),
        ],
      );
      expect(container.read(localeProvider), const Locale('ta'));
    });

    test('an empty phone list is English, not a crash', () async {
      final (container, _) = await boot(phone: const []);
      expect(container.read(localeProvider), const Locale('en'));
    });

    test('the fallback is NOT persisted — the phone stays in charge', () async {
      final (container, prefs) = await boot(phone: const [Locale('ml')]);

      expect(container.read(localeProvider), const Locale('ml'));
      expect(
        prefs.getString('arul_locale'),
        isNull,
        reason:
            'writing it would freeze the app to the phone language of the '
            'first launch, and show Settings a choice nobody made',
      );
    });
  });

  group('an explicit pick outranks the phone', () {
    test('persisted English on a Tamil phone stays English', () async {
      final (container, _) = await boot(
        persisted: 'en',
        phone: const [Locale('ta')],
      );
      expect(container.read(localeProvider), const Locale('en'));
    });

    test('persisted Hindi on a Tamil phone stays Hindi', () async {
      final (container, _) = await boot(
        persisted: 'hi',
        phone: const [Locale('ta')],
      );
      expect(container.read(localeProvider), const Locale('hi'));
    });

    test('a pick persists, and the phone no longer decides', () async {
      final (container, prefs) = await boot(phone: const [Locale('ta')]);

      await container
          .read(localeProvider.notifier)
          .setLocale(const Locale('te'));

      expect(container.read(localeProvider), const Locale('te'));
      expect(prefs.getString('arul_locale'), 'te');
    });

    test('a persisted code the app no longer ships reads as English', () async {
      final (container, _) = await boot(
        persisted: 'fr',
        phone: const [Locale('ta')],
      );
      expect(
        container.read(localeProvider),
        const Locale('en'),
        reason: 'a stale pick must not silently become the phone language',
      );
    });
  });

  group('the language tables have ONE home', () {
    test('every supported locale has both names', () {
      for (final locale in supportedAppLocales) {
        expect(appLanguageNames, contains(locale.languageCode));
        expect(appLanguageNativeNames, contains(locale.languageCode));
      }
      expect(appLanguageNames, hasLength(supportedAppLocales.length));
      expect(appLanguageNativeNames, hasLength(supportedAppLocales.length));
    });

    test('the English name the sheet returns round-trips to its code', () {
      for (final locale in supportedAppLocales) {
        final code = locale.languageCode;
        expect(appLanguageCodeFor(appLanguageName(code)), code);
      }
      expect(appLanguageCodeFor('Klingon'), isNull);
    });

    test('an unknown code falls back to English on both tables', () {
      expect(appLanguageName('zz'), 'English');
      expect(appLanguageNativeName('zz'), 'English');
    });
  });
}
