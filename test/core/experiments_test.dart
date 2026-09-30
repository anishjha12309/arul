// The regional wall's plumbing after the A/B: every install gets it, a stored arm is read back
// unchanged and stamped as the ASSIGNMENT, and only an explicit `feature_flags` false switches the
// wall off, from the next cold start.

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

  group('after the test', () {
    test('an install without an arm gets the regional wall and stamps no arm', () async {
      final none = Experiments.read(await prefsWith({}));
      expect(none.regional, isNull);
      expect(none.analyticsProperties, isEmpty);
      expect(none.regionalActive, isTrue);
      expect(none.geoLanguageApplies, isTrue);
    });

    test('a control install gets the regional wall too, and keeps its arm', () async {
      final control = Experiments.read(
        await prefsWith({Experiments.regionalKey: 'control'}),
      );
      expect(control.regional, RegionalArm.control);
      expect(control.analyticsProperties, {'exp_regional': 'control'});
      expect(control.regionalActive, isTrue);
      // A hint a control install stored was never applied -> applying it now would flip its language.
      expect(control.geoLanguageApplies, isFalse);
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
      'only the arm that could have taken a region language keeps it',
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
      'a regional install keeps the region language an older build stored',
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
  });
}
