// The sign-in factorial's plumbing: two coins dealt once per fresh install, read back unchanged on
// every launch, stamped on analytics as the ASSIGNMENT, and switched off only by an explicit
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
    test('a fresh install gets both arms, an update gets none', () async {
      final fresh = await prefsWith({});
      Experiments.drawIfFreshInstall(fresh, freshInstall: true);
      final dealt = Experiments.read(fresh);
      expect(dealt.regional, isNotNull);
      expect(dealt.reminder, isNotNull);

      final update = await prefsWith({});
      Experiments.drawIfFreshInstall(update, freshInstall: false);
      final none = Experiments.read(update);
      expect(none.regional, isNull);
      expect(none.reminder, isNull);
      expect(none.analyticsProperties, isEmpty);
      // An install outside the factorial keeps today's app: the region may pick the language.
      expect(none.geoLanguageApplies, isTrue);
      expect(none.regionalActive, isFalse);
      expect(none.reminderActive, isFalse);
    });

    test('a stored arm is never re-dealt', () async {
      final prefs = await prefsWith({
        Experiments.regionalKey: 'regional',
        Experiments.reminderKey: 'control',
      });
      for (var seed = 0; seed < 20; seed++) {
        Experiments.drawIfFreshInstall(
          prefs,
          freshInstall: true,
          random: Random(seed),
        );
        final e = Experiments.read(prefs);
        expect(e.regional, RegionalArm.regional);
        expect(e.reminder, ReminderArm.control);
      }
    });

    test('the two coins are independent and fair', () async {
      final counts = <String, int>{};
      final rng = Random(7);
      for (var i = 0; i < 4000; i++) {
        final prefs = await prefsWith({});
        Experiments.drawIfFreshInstall(prefs, freshInstall: true, random: rng);
        final e = Experiments.read(prefs);
        final cell = '${e.regional!.name}/${e.reminder!.name}';
        counts[cell] = (counts[cell] ?? 0) + 1;
      }
      expect(counts.keys, hasLength(4));
      for (final n in counts.values) {
        expect(n, inInclusiveRange(880, 1120));
      }
    });

    test('the QA seam deals named arms and control for the rest', () async {
      final both = await prefsWith({});
      Experiments.drawIfFreshInstall(
        both,
        freshInstall: true,
        qaArms: 'regional,reminder',
      );
      expect(Experiments.read(both).regional, RegionalArm.regional);
      expect(Experiments.read(both).reminder, ReminderArm.reminder);

      final one = await prefsWith({});
      Experiments.drawIfFreshInstall(
        one,
        freshInstall: true,
        qaArms: 'reminder',
      );
      expect(Experiments.read(one).regional, RegionalArm.control);
      expect(Experiments.read(one).reminder, ReminderArm.reminder);
    });
  });

  group('what the arms mean', () {
    test('analytics carries the assignment even when switched off', () async {
      final prefs = await prefsWith({
        Experiments.regionalKey: 'regional',
        Experiments.reminderKey: 'reminder',
        Experiments.regionalOffKey: true,
      });
      final e = Experiments.read(prefs);
      expect(e.analyticsProperties, {
        'exp_regional': 'regional',
        'exp_reminder': 'reminder',
      });
      expect(e.regionalActive, isFalse);
      expect(e.reminderActive, isTrue);
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

  group('kill switches', () {
    test(
      'only an explicit false turns an arm off, and true turns it back on',
      () async {
        final prefs = await prefsWith({});
        await Experiments.persistKillSwitches(prefs, {'exp_regional': false});
        expect(Experiments.read(prefs).regionalOff, isTrue);
        expect(Experiments.read(prefs).reminderOff, isFalse);

        await Experiments.persistKillSwitches(prefs, {'exp_regional': true});
        expect(Experiments.read(prefs).regionalOff, isFalse);

        await Experiments.persistKillSwitches(prefs, {'exp_reminder': false});
        await Experiments.persistKillSwitches(prefs, null);
        expect(Experiments.read(prefs).reminderOff, isTrue);
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
