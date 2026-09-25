// The regional arm's launch art: the owner-approved region table, the one-shot settle that keeps a
// late `/geo` answer from swapping the poster under the wall, and the posters actually bundled.

import 'dart:async';
import 'dart:io';

import 'package:fake_async/fake_async.dart';

import 'package:arul/core/experiments/experiments.dart';
import 'package:arul/core/providers/geo_language_service.dart';
import 'package:arul/core/providers/locale_provider.dart';
import 'package:arul/core/providers/shared_preferences_provider.dart';
import 'package:arul/features/auth/domain/regional_art.dart';
import 'package:arul/features/auth/providers/launch_art_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the region table', () {
    for (final r in ['TN', 'KA', 'TS', 'TG', 'AP', 'DL', 'MH', 'GJ', 'WB']) {
      expect(regionalPosterFor(r), RegionalPoster.murugan, reason: r);
    }
    expect(regionalPosterFor('KL'), RegionalPoster.ayyappan);
    expect(regionalPosterFor('Kerala'), RegionalPoster.ayyappan);
    for (final r in ['UP', 'BR', 'MP', 'RJ', 'HR', 'JH', 'CG', 'UK', 'HP']) {
      expect(regionalPosterFor(r), RegionalPoster.sivan, reason: r);
    }
    expect(regionalPosterFor('Uttar Pradesh'), RegionalPoster.sivan);
    expect(regionalPosterFor(null), RegionalPoster.murugan);
    expect(regionalPosterFor('none'), RegionalPoster.murugan);
  });

  test('every poster is bundled, declared and inside the size budget', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec, contains('- assets/images/regional/'));
    for (final p in RegionalPoster.all) {
      final file = File(p.asset);
      expect(file.existsSync(), isTrue, reason: p.asset);
      // ≤60 KB is the target; the detail-dense Murugan frame needs a little more to stay clean.
      expect(file.lengthSync(), lessThan(80 * 1024), reason: p.asset);
    }
  });

  Future<ProviderContainer> boot(Map<String, Object> values) async {
    SharedPreferences.setMockInitialValues(values);
    final prefs = await SharedPreferences.getInstance();
    final c = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(c.dispose);
    return c;
  }

  test('control and installs outside the factorial keep the lotus', () async {
    expect(
      (await boot({
        Experiments.regionalKey: 'control',
      })).read(launchArtProvider),
      isA<LotusArt>(),
    );
    expect((await boot({})).read(launchArtProvider), isA<LotusArt>());
    expect(
      (await boot({
        Experiments.regionalKey: 'regional',
        Experiments.regionalOffKey: true,
      })).read(launchArtProvider),
      isA<LotusArt>(),
    );
  });

  test(
    'the regional arm with a stored region paints its poster at once',
    () async {
      final c = await boot({
        Experiments.regionalKey: 'regional',
        geoRegionPrefsKey: 'KL',
      });
      expect(
        c.read(launchArtProvider),
        const PosterArt(RegionalPoster.ayyappan),
      );
    },
  );

  test(
    'awaiting settles once, and a later answer never swaps the poster',
    () async {
      final c = await boot({
        Experiments.regionalKey: 'regional',
        geoPendingPrefsKey: true,
      });
      expect(c.read(launchArtProvider), isA<AwaitingRegionArt>());

      // The cap passed with no answer -> the default.
      c.read(launchArtProvider.notifier).settle();
      expect(
        c.read(launchArtProvider),
        const PosterArt(RegionalPoster.murugan),
      );

      await c
          .read(sharedPreferencesProvider)
          .setString(geoRegionPrefsKey, 'UP');
      c.read(launchArtProvider.notifier).settle();
      expect(
        c.read(launchArtProvider),
        const PosterArt(RegionalPoster.murugan),
      );
    },
  );

  test('an answer inside the cap picks the region poster', () async {
    final c = await boot({
      Experiments.regionalKey: 'regional',
      geoPendingPrefsKey: true,
    });
    await c.read(sharedPreferencesProvider).setString(geoRegionPrefsKey, 'UP');
    c.read(launchArtProvider.notifier).settle();
    expect(c.read(launchArtProvider), const PosterArt(RegionalPoster.sivan));
  });

  group('the regional wait', () {
    test('an answer inside the cap ends the wait when it lands', () {
      fakeAsync((clock) {
        final ask = Completer<void>();
        bool? answered;
        awaitRegionAnswer(ask.future, const Duration(milliseconds: 1200))
            .then((a) => answered = a);
        clock.elapse(const Duration(milliseconds: 400));
        expect(answered, isNull);
        ask.complete();
        clock.flushMicrotasks();
        expect(answered, isTrue);
      });
    });

    test('no answer ends the wait at the cap, and a late one changes nothing', () {
      fakeAsync((clock) {
        final ask = Completer<void>();
        bool? answered;
        awaitRegionAnswer(ask.future, const Duration(milliseconds: 1200))
            .then((a) => answered = a);
        clock.elapse(const Duration(milliseconds: 1199));
        expect(answered, isNull);
        clock.elapse(const Duration(milliseconds: 1));
        expect(answered, isFalse);
        ask.complete();
        clock.flushMicrotasks();
        expect(answered, isFalse);
      });
    });

    test('a spent budget does not wait at all', () async {
      expect(await awaitRegionAnswer(Completer<void>().future, Duration.zero), isFalse);
    });
  });
}
