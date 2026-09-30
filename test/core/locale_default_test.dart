// The app's language when nobody has picked one.
//
// A Tamil phone that opened Arul in English had to be told, in English, where the picker was. So an
// unset preference follows the PHONE. The trap this pins is the other half: the phone fallback is
// never written down. Persisting it would freeze the app to whatever the phone said on first
// launch, and would show Settings a language the user never chose as if they had.
//
// The REGION never picks the language: `GET /geo` stores only the region, for the launch poster. A
// region language an older build stored is still honoured, so no install flips on update.

import 'dart:async';
import 'dart:convert';

import 'package:arul/core/analytics/analytics_cohort.dart';
import 'package:arul/core/analytics/journey_stamps.dart';
import 'package:arul/core/api/api_client.dart';
import 'package:arul/core/deeplink/deep_link_locale_sync.dart';
import 'package:arul/core/deeplink/deep_link_target.dart';
import 'package:arul/core/providers/geo_region_service.dart';
import 'package:arul/core/providers/locale_provider.dart';
import 'package:arul/core/providers/shared_preferences_provider.dart';
import 'package:arul/features/auth/providers/auth_providers.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  Future<(ProviderContainer, SharedPreferences)> boot({
    String? persisted,
    String? persistedSource,
    String? geo,
    String? region,
    bool pending = false,
    List<Locale> phone = const [Locale('en')],
    http.Client? network,
  }) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'arul_locale': ?persisted,
      'arul_locale_source': ?persistedSource,
      'arul_geo_lang': ?geo,
      'arul_geo_region': ?region,
      if (pending) 'arul_geo_pending': true,
    });
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        platformLocalesProvider.overrideWithValue(phone),
        if (network != null)
          apiClientProvider.overrideWithValue(ApiClient(httpClient: network)),
      ],
    );
    addTearDown(container.dispose);
    return (container, prefs);
  }

  /// The Worker's answer, as `routes/geo.ts` shapes it.
  http.Response geoAnswer(Map<String, Object?> body, [int status = 200]) =>
      http.Response(
        jsonEncode(body),
        status,
        headers: {'content-type': 'application/json'},
      );

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
          .setLocale(const Locale('te'), source: LanguageSource.pick);

      expect(container.read(localeProvider), const Locale('te'));
      expect(prefs.getString('arul_locale'), 'te');
      expect(prefs.getString('arul_locale_source'), 'pick');
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

  group("an older build's region language is kept, never a pick", () {
    test('a stored region language beats the phone', () async {
      // The install already opened in it -> dropping it on update would flip its language.
      final (container, _) = await boot(geo: 'ta', phone: const [Locale('en')]);
      expect(container.read(localeProvider), const Locale('ta'));
    });

    test('a stored region language beats a SUPPORTED phone language', () async {
      final (container, _) = await boot(geo: 'hi', phone: const [Locale('kn')]);
      expect(container.read(localeProvider), const Locale('hi'));
    });

    test('a pick beats geo', () async {
      final (container, _) = await boot(persisted: 'en', geo: 'ta');
      expect(container.read(localeProvider), const Locale('en'));
    });

    test('`none` and an unknown code are ignored', () async {
      final (none, _) = await boot(geo: 'none', phone: const [Locale('kn')]);
      expect(none.read(localeProvider), const Locale('kn'));

      final (unknown, _) = await boot(geo: 'fr', phone: const [Locale('kn')]);
      expect(unknown.read(localeProvider), const Locale('kn'));

      final (neither, _) = await boot(geo: 'none', phone: const [Locale('fr')]);
      expect(neither.read(localeProvider), const Locale('en'));
    });

    testWidgets('a `lang=` link after geo wins and persists', (tester) async {
      ArulDeepLink.reset();
      addTearDown(ArulDeepLink.reset);
      SharedPreferences.setMockInitialValues(<String, Object>{
        'arul_geo_lang': 'ta',
        'arul_geo_region': 'TN',
      });
      final prefs = await SharedPreferences.getInstance();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
          child: const DeepLinkLocaleSync(child: SizedBox.shrink()),
        ),
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(DeepLinkLocaleSync)),
      );
      expect(container.read(localeProvider), const Locale('ta'));

      ArulDeepLink.requestLocale('kn');
      await tester.pump();

      expect(container.read(localeProvider), const Locale('kn'));
      expect(prefs.getString('arul_locale'), 'kn');
      expect(prefs.getString('arul_locale_source'), 'link');
      expect(
        container.read(languageOriginProvider).source,
        LanguageSource.link,
      );
    });
  });

  group('language_source says which rung decided', () {
    test('every rung of the chain', () {
      const en = [Locale('en')];
      expect(
        resolveLanguageSource('ta', 'link', 'hi', en),
        LanguageSource.link,
      );
      expect(
        resolveLanguageSource('ta', 'pick', 'hi', en),
        LanguageSource.pick,
      );
      expect(resolveLanguageSource(null, null, 'hi', en), LanguageSource.geo);
      expect(
        resolveLanguageSource(null, null, 'none', const [Locale('ta')]),
        LanguageSource.phone,
      );
      expect(
        resolveLanguageSource(null, null, null, const [Locale('fr')]),
        LanguageSource.fallback,
      );
      expect(LanguageSource.fallback.key, 'default');
    });

    test('a pick stored before the source was recorded reads as a pick', () {
      expect(
        resolveLanguageSource('ta', null, null, const [Locale('en')]),
        LanguageSource.pick,
      );
    });

    test('a region answer re-stamps geo_region, never the source', () async {
      final (container, _) = await boot(
        pending: true,
        phone: const [Locale('ta')],
        network: MockClient(
          (_) async =>
              geoAnswer({'country': 'IN', 'region': 'TN', 'lang': null}),
        ),
      );
      final seen = <LanguageOrigin>[];
      container.listen(
        languageOriginProvider,
        (_, next) => seen.add(next),
        fireImmediately: true,
      );
      expect(seen.single, (source: LanguageSource.phone, geoRegion: 'none'));

      await container.read(geoRegionServiceProvider).fetchOnce();
      await container.pump();

      expect(seen.last, (source: LanguageSource.phone, geoRegion: 'TN'));
    });

    test(
      'a pick of the language already showing still reports `pick`',
      () async {
        final (container, _) = await boot(geo: 'ta', region: 'TN');
        expect(
          container.read(languageOriginProvider).source,
          LanguageSource.geo,
        );

        await container
            .read(localeProvider.notifier)
            .setLocale(const Locale('ta'), source: LanguageSource.pick);

        expect(
          container.read(languageOriginProvider).source,
          LanguageSource.pick,
        );
        expect(container.read(languageOriginProvider).geoRegion, 'TN');
      },
    );

    test("geo_region is the raw region, `none`, or cut to GA4's 36", () {
      expect(geoRegionValue('TN'), 'TN');
      expect(geoRegionValue(null), 'none');
      expect(geoRegionValue(''), 'none');
      expect(geoRegionValue('X' * 50), 'X' * 36);
    });
  });

  group('GET /geo — once per FRESH install, region only', () {
    setUp(JourneyStamps.debugReset);

    test('a fresh install arms the fetch; an upgrade never does', () async {
      // An upgrade already holds a cohort draw -> isFreshInstall is false -> no pending, no fetch.
      addTearDown(AnalyticsCohort.debugReset);
      SharedPreferences.setMockInitialValues(<String, Object>{
        'analytics_posthog_cohort_draw_v1': 0.4,
      });
      final upgrade = await SharedPreferences.getInstance();
      AnalyticsCohort.resolve(upgrade);
      GeoRegionService.markIfFreshInstall(
        upgrade,
        freshInstall: AnalyticsCohort.isFreshInstall,
      );
      expect(upgrade.getBool('arul_geo_pending'), isNull);

      SharedPreferences.setMockInitialValues(<String, Object>{});
      final fresh = await SharedPreferences.getInstance();
      AnalyticsCohort.resolve(fresh);
      GeoRegionService.markIfFreshInstall(
        fresh,
        freshInstall: AnalyticsCohort.isFreshInstall,
      );
      expect(fresh.getBool('arul_geo_pending'), isTrue);
    });

    test('an upgrade never calls the Worker and stamps nothing', () async {
      var calls = 0;
      final (container, _) = await boot(
        network: MockClient((_) async {
          calls++;
          return geoAnswer({'country': 'IN', 'region': 'TN', 'lang': null});
        }),
      );

      expect(container.read(geoRegionServiceProvider).willAsk, isFalse);
      await container.read(geoRegionServiceProvider).fetchOnce();

      expect(calls, 0);
      expect(JourneyStamps.geoProps, isEmpty);
    });

    test(
      'a fresh install asks ONCE, stores the region and keeps the language',
      () async {
        final requests = <http.BaseRequest>[];
        final (container, prefs) = await boot(
          pending: true,
          network: MockClient((request) async {
            requests.add(request);
            // An older Worker still answering a language must change nothing.
            return geoAnswer({'country': 'IN', 'region': 'TN', 'lang': 'ta'});
          }),
        );
        final geo = container.read(geoRegionServiceProvider);
        expect(geo.willAsk, isTrue);

        await geo.fetchOnce();
        await geo.fetchOnce();

        expect(geo.willAsk, isFalse);
        expect(requests, hasLength(1));
        expect(requests.single.method, 'GET');
        expect(requests.single.url.path, '/geo');
        expect(requests.single.headers.containsKey('Authorization'), isFalse);
        expect(container.read(localeProvider), const Locale('en'));
        expect(prefs.getBool('arul_geo_pending'), isNull);
        expect(prefs.getString('arul_geo_region'), 'TN');
        expect(prefs.getString('arul_geo_lang'), isNull);
        expect(prefs.getString('arul_locale'), isNull);
        expect(JourneyStamps.geoProps['geo_outcome'], 'answered');
        expect(JourneyStamps.geoProps['geo_ms'], isA<int>());
        expect(
          container.read(apiClientProvider).firstWarmUpMs,
          isNotNull,
          reason: '/geo opened the socket -> the launch clip reads its time',
        );
      },
    );

    test('a region the Worker cannot place is stored as `none`', () async {
      final (container, prefs) = await boot(
        pending: true,
        network: MockClient(
          (_) async => geoAnswer({'country': null, 'region': null, 'lang': null}),
        ),
      );

      await container.read(geoRegionServiceProvider).fetchOnce();

      expect(prefs.getString('arul_geo_region'), 'none');
      expect(prefs.getBool('arul_geo_pending'), isNull);
    });

    test(
      'an offline first launch keeps pending; the next cold start retries',
      () async {
        final (container, prefs) = await boot(
          pending: true,
          network: MockClient(
            (_) async => throw http.ClientException('offline'),
          ),
        );

        await container.read(geoRegionServiceProvider).fetchOnce();

        expect(prefs.getBool('arul_geo_pending'), isTrue);
        expect(prefs.getString('arul_geo_region'), isNull);
        expect(JourneyStamps.geoProps['geo_outcome'], 'failed');

        // The next process: same prefs, the network back.
        final next = ProviderContainer(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            platformLocalesProvider.overrideWithValue(const [Locale('en')]),
            apiClientProvider.overrideWithValue(
              ApiClient(
                httpClient: MockClient(
                  (_) async => geoAnswer({
                    'country': 'IN',
                    'region': 'KL',
                    'lang': 'ml',
                  }),
                ),
              ),
            ),
          ],
        );
        addTearDown(next.dispose);
        await next.read(geoRegionServiceProvider).fetchOnce();

        expect(next.read(localeProvider), const Locale('en'));
        expect(prefs.getString('arul_geo_region'), 'KL');
        expect(prefs.getBool('arul_geo_pending'), isNull);
      },
    );

    test('a route that is not live yet (404) keeps pending', () async {
      final (container, prefs) = await boot(
        pending: true,
        network: MockClient(
          (_) async => geoAnswer({
            'error': {'code': 'not_found', 'message': 'Route not found'},
          }, 404),
        ),
      );

      await container.read(geoRegionServiceProvider).fetchOnce();

      expect(prefs.getBool('arul_geo_pending'), isTrue);
      expect(prefs.getString('arul_geo_region'), isNull);
    });

    test(
      'a timed-out first launch keeps pending and asks once per process',
      () async {
        var calls = 0;
        final (container, prefs) = await boot(
          pending: true,
          network: MockClient((_) {
            calls++;
            return Completer<http.Response>().future;
          }),
        );
        final service = GeoRegionService(
          api: container.read(apiClientProvider),
          prefs: prefs,
          onRegion: () {},
          timeout: const Duration(milliseconds: 20),
        );

        await service.fetchOnce();
        await service.fetchOnce();

        expect(calls, 1, reason: 'at most one call per cold start');
        expect(prefs.getBool('arul_geo_pending'), isTrue);
        expect(JourneyStamps.geoProps['geo_outcome'], 'failed');
      },
    );

    test(
      'settled completes on a failed ask and at once with nothing to ask',
      () async {
        final (container, prefs) = await boot(
          pending: true,
          network: MockClient((_) => Completer<http.Response>().future),
        );
        final failing = GeoRegionService(
          api: container.read(apiClientProvider),
          prefs: prefs,
          onRegion: () {},
          timeout: const Duration(milliseconds: 20),
        );
        var settled = false;
        unawaited(failing.settled.then((_) => settled = true));
        await failing.fetchOnce();
        await Future<void>.delayed(Duration.zero);
        expect(settled, isTrue);

        await prefs.remove('arul_geo_pending');
        final idle = GeoRegionService(
          api: container.read(apiClientProvider),
          prefs: prefs,
          onRegion: () {},
        );
        await idle.fetchOnce();
        await idle.settled;
      },
    );
  });

  // main() stamps `Application Installed` with the language before Riverpod exists -> it must read
  // the same keys and resolve the same way, or the install event disagrees with every later event.
  test('the pre-Riverpod resolution matches the provider', () async {
    final (container, prefs) = await boot(
      persisted: 'hi',
      phone: const [Locale('ta')],
    );
    expect(
      resolveAppLocale(
        prefs.getString(appLocalePrefsKey),
        prefs.getString(geoLangPrefsKey),
        const [Locale('ta')],
      ),
      container.read(localeProvider),
    );
    expect(
      resolveAppLocale(null, null, const [Locale('ta')]),
      const Locale('ta'),
    );

    final (geo, geoPrefs) = await boot(geo: 'ml', region: 'KL');
    expect(
      resolveAppLocale(
        geoPrefs.getString(appLocalePrefsKey),
        geoPrefs.getString(geoLangPrefsKey),
        const [Locale('en')],
      ),
      geo.read(localeProvider),
    );
    expect(
      resolveLanguageOrigin(geoPrefs, const [Locale('en')]),
      geo.read(languageOriginProvider),
    );
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
