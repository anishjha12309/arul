import 'dart:io';

import 'package:arul/features/ringtones/presentation/deity_art.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('deityAsset resolution chain', () {
    test('a known deity gets its own art', () {
      expect(
        deityAsset(deity: 'ganesha', category: 'others'),
        'assets/ringtones/ganesha.webp',
      );
      expect(
        deityAsset(deity: 'venkateswara', category: 'perumal'),
        'assets/ringtones/venkateswara.webp',
      );
    });

    test('the deity wins over the category', () {
      // A Rama track lives in `perumal`, whose default is the generic Vishnu.
      // If the category ever won, every named form in the category would lose
      // its art — which is the whole reason the column exists.
      expect(
        deityAsset(deity: 'rama', category: 'perumal'),
        'assets/ringtones/rama.webp',
      );
    });

    test('a null deity falls back to the category default', () {
      expect(
        deityAsset(deity: null, category: 'murugan'),
        'assets/ringtones/murugan.webp',
      );
      expect(
        deityAsset(deity: null, category: 'perumal'),
        'assets/ringtones/vishnu.webp',
      );
      expect(
        deityAsset(deity: null, category: 'amman'),
        'assets/ringtones/devi.webp',
      );
    });

    test('a deity this release has never heard of falls to its category', () {
      // The catalog can move ahead of the app: a bulk import can invent a slug
      // months before the WebP ships. That row must still look like the right
      // family of god, not like a temple.
      expect(
        deityAsset(deity: 'kartikeya', category: 'murugan'),
        'assets/ringtones/murugan.webp',
      );
    });

    test('others and temples reach the neutral fallback, never a deity', () {
      // `others` holds gods deliberately unlike each other, so there is no
      // honest default — a wrong face is worse than a temple.
      expect(deityAsset(deity: null, category: 'others'), kFallbackDeityAsset);
      expect(deityAsset(deity: null, category: 'temples'), kFallbackDeityAsset);
    });

    test('an unknown category reaches the fallback', () {
      expect(
        deityAsset(deity: null, category: 'navagraha'),
        kFallbackDeityAsset,
      );
      expect(deityAsset(deity: null, category: null), kFallbackDeityAsset);
      expect(deityAsset(deity: '', category: ''), kFallbackDeityAsset);
    });

    test('slugs are matched case- and whitespace-insensitively', () {
      // Both fields are free text off the catalog; a `Murugan` typed into the
      // CMS must not silently drop the row to the gopuram.
      expect(
        deityAsset(deity: 'Ganesha', category: 'others'),
        'assets/ringtones/ganesha.webp',
      );
      expect(
        deityAsset(deity: '  hanuman  ', category: 'others'),
        'assets/ringtones/hanuman.webp',
      );
      expect(
        deityAsset(deity: null, category: ' PERUMAL '),
        'assets/ringtones/vishnu.webp',
      );
    });
  });

  group('bundled assets', () {
    // The failure this guards is invisible in CI and fatal on a device: a slug
    // in the set with no WebP behind it throws mid-paint, and only on the row
    // that happens to use it.
    test('every declared slug has a file on disk', () {
      for (final path in allDeityAssets) {
        expect(
          File(path).existsSync(),
          isTrue,
          reason: '$path is declared in deity_art.dart but not bundled',
        );
      }
    });

    test('every bundled webp is declared', () {
      final onDisk = Directory('assets/ringtones')
          .listSync()
          .whereType<File>()
          .map((f) => f.path.replaceAll(r'\', '/'))
          .where((p) => p.endsWith('.webp'))
          .toSet();
      expect(onDisk, isNotEmpty);
      expect(
        onDisk.difference(allDeityAssets.toSet()),
        isEmpty,
        reason: 'an unreferenced webp is dead weight in the AAB',
      );
    });

    test('the category defaults point at real, generic art', () {
      // vishnu and devi stand in for every unidentified track in their family,
      // so they must exist AND must not be a named form.
      for (final slug in ['vishnu', 'devi']) {
        expect(kDeityArtSlugs, contains(slug));
        expect(File('assets/ringtones/$slug.webp').existsSync(), isTrue);
      }
    });
  });
}
