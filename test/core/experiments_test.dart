// The regional wall's plumbing: one coin dealt once per fresh install, read back unchanged on every
// launch, stamped on analytics as the ASSIGNMENT, and switched off only by an explicit
// `feature_flags` false that takes effect from the next cold start.

import 'dart:math';

import 'package:arul/core/experiments/experiments.dart';
import 'package:arul/core/providers/locale_provider.dart';
import 'package:arul/core/providers/shared_preferences_provider.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<SharedPreferences> prefsWith(Map<String, Object> values) async {
    SharedPreferences.setMockInitialValues(values);
    return SharedPreferences.getInstance();
  }

  group('the draw', () {
    test('a fresh install gets an arm, an update gets none', () async {
      final fresh = await prefsWith({});
      Experiments.drawIfFreshInstall(fresh, freshInstall: true);
      final dealt = Experiments.read(fresh);
      expect(dealt.regional, isNotNull);
      expect(fresh.getString('arul_exp_reminder_v1'), isNull);

      final update = await prefsWith({});
      Experiments.drawIfFreshInstall(update, freshInstall: false);
      final none = Experiments.read(update);
      expect(none.regional, isNull);
      expect(none.analyticsProperties, isEmpty);
      // An install outside the factorial keeps today's app: the region may pick the language.
      expect(none.geoLanguageApplies, isTrue);
      expect(none.regionalActive, isFalse);
    });

    test('a stored arm is never re-dealt', () async {
      final prefs = await prefsWith({
        Experiments.regionalKey: 'regional',
      });
      for (var seed = 0; seed < 20; seed++) {
        Experiments.drawIfFreshInstall(
          prefs,
          freshInstall: true,
          random: Random(seed),
        );
        final e = Experiments.read(prefs);
        expect(e.regional, RegionalArm.regional);
      }
    });

    test('the coin is fair', () async {
      final counts = <String, int>{};
      final rng = Random(7);
      for (var i = 0; i < 4000; i++) {
        final prefs = await prefsWith({});
        Experiments.drawIfFreshInstall(prefs, freshInstall: true, random: rng);
        final cell = Experiments.read(prefs).regional!.name;
        counts[cell] = (counts[cell] ?? 0) + 1;
      }
      expect(counts.keys, hasLength(2));
      for (final n in counts.values) {
        expect(n, inInclusiveRange(1880, 2120));
      }
    });

    test('the QA seam deals the named arm, anything else is control', () async {
      final named = await prefsWith({});
      Experiments.drawIfFreshInstall(
        named,
        freshInstall: true,
        qaArms: 'regional',
      );
      expect(Experiments.read(named).regional, RegionalArm.regional);

      final other = await prefsWith({});
      Experiments.drawIfFreshInstall(
        other,
        freshInstall: true,
        qaArms: 'reminder',
      );
      expect(Experiments.read(other).regional, RegionalArm.control);
    });
  });

  group('what the arms mean', () {
    test('analytics carries the assignment even when switched off', () async {
      final prefs = await prefsWith({
        Experiments.regionalKey: 'regional',
        Experiments.regionalOffKey: true,
        // A retired coin an older build stored is ignored, never stamped.
        'arul_exp_reminder_v1': 'reminder',
      });
      final e = Experiments.read(prefs);
      expect(e.analyticsProperties, {'exp_regional': 'regional'});
      expect(e.regionalActive, isFalse);
    });

    test(
      'only the regional arm (active) lets the region choose the language',
      () async {
        Future<bool> applies(Map<String, Object> v) async =>
            Experiments.read(await prefsWith(v)).geoLanguageApplies;
        expect(await applies({Experiments.regionalKey: 'regional'}), isTrue);
        expect(await applies({Experiments.regionalKey: 'control'}), isFalse);
        expect(
          await applies({
            Experiments.regionalKey: 'regional',
            Experiments.regionalOffKey: true,
          }),
          isFalse,
        );
      },
    );
  });

  group('kill switch', () {
    test(
      'only an explicit false turns the arm off, and true turns it back on',
      () async {
        final prefs = await prefsWith({});
        await Experiments.persistKillSwitches(prefs, {'exp_regional': false});
        expect(Experiments.read(prefs).regionalOff, isTrue);

        await Experiments.persistKillSwitches(prefs, null);
        expect(Experiments.read(prefs).regionalOff, isTrue);

        await Experiments.persistKillSwitches(prefs, {'exp_regional': true});
        expect(Experiments.read(prefs).regionalOff, isFalse);
      },
    );
  });

  group('the control arm and the region', () {
    Future<ProviderContainer> boot(Map<String, Object> values) async {
      final prefs = await prefsWith(values);
      final c = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          platformLocalesProvider.overrideWithValue(const [Locale('en')]),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    test('control stores the region but keeps the phone language', () async {
      final c = await boot({
        Experiments.regionalKey: 'control',
        geoPendingPrefsKey: true,
      });
      await c
          .read(localeProvider.notifier)
          .setGeoHint(lang: 'ta', region: 'TN');
      expect(c.read(localeProvider), const Locale('en'));
      expect(c.read(languageOriginProvider).source, LanguageSource.phone);
      expect(c.read(languageOriginProvider).geoRegion, 'TN');
    });

    test(
      'control ignores a stored region language on the next launch too',
      () async {
        final c = await boot({
          Experiments.regionalKey: 'control',
          geoLangPrefsKey: 'ta',
          geoRegionPrefsKey: 'TN',
        });
        expect(c.read(localeProvider), const Locale('en'));
      },
    );

    test(
      'the regional arm applies a stored region language from the first frame',
      () async {
        final c = await boot({
          Experiments.regionalKey: 'regional',
          geoLangPrefsKey: 'ml',
          geoRegionPrefsKey: 'KL',
        });
        expect(c.read(localeProvider), const Locale('ml'));
        expect(c.read(languageOriginProvider).source, LanguageSource.geo);
      },
    );

    test(
      'an answer after the cap is stored for the next launch, never applied now',
      () async {
        final c = await boot({
          Experiments.regionalKey: 'regional',
          geoPendingPrefsKey: true,
        });
        // The root listener has read the origin long before the answer lands.
      expect(c.read(languageOriginProvider).source, LanguageSource.phone);
      await c
            .read(localeProvider.notifier)
            .setGeoHint(lang: 'ta', region: 'TN', applyLive: false);
        expect(c.read(localeProvider), const Locale('en'));
        expect(c.read(languageOriginProvider).source, LanguageSource.phone);

        final prefs = c.read(sharedPreferencesProvider);
        expect(prefs.getString(geoLangPrefsKey), 'ta');
        expect(prefs.getBool(geoPendingPrefsKey), isNull);
      },
    );
  });
}
