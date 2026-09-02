// The operator's chip order out of the unified CMS, and what it may NOT do.
//
// The order reaches the app as `app_config.category_order` -> a per-scope list of slugs,
// written by dragging rows on the CMS Categories page and emitted by build-catalog.
// It decides ORDER ONLY: a chip exists because a PUBLISHED row carries the slug, so this
// list can never add a category the catalog lacks nor hide one it has. Every assertion
// below is about that boundary, because nothing else in the app would catch it slipping.
//
// The fallback is load-bearing in three separate situations that all look the same here:
// an install older than the field, a CMS nobody has dragged, and a config fetch that has
// not landed (or failed). All three must leave the built-in rule in sole charge.

import 'package:flutter_test/flutter_test.dart';

import 'package:arul/data/models/wallpaper.dart';
import 'package:arul/features/ringtones/providers/ringtone_catalog_providers.dart';

WallpaperCategory _cat(String slug) =>
    WallpaperCategory(slug, slug[0].toUpperCase() + slug.substring(1));

List<String> _slugs(List<WallpaperCategory> cats) =>
    cats.map((c) => c.slug).toList();

void main() {
  final wallpapers = [
    _cat('perumal'),
    _cat('amman'),
    _cat('sivan'),
    _cat('temples'),
    _cat('murugan'),
    _cat('ayyappan'),
  ];
  final ringtones = [
    _cat('perumal'),
    _cat('others'),
    _cat('amman'),
    _cat('murugan'),
    _cat('sivan'),
    _cat('ayyappan'),
  ];

  group('no CMS order -> the built-in rule is untouched', () {
    test('wallpapers keep Sivan first, then alphabetical', () {
      expect(
        _slugs(orderedByCms(wallpapers.toList(), const [], compareBrowseCategories)),
        ['sivan', 'amman', 'ayyappan', 'murugan', 'perumal', 'temples'],
      );
    });

    test('ringtones keep Sivan first and `others` last', () {
      expect(
        _slugs(orderedByCms(ringtones.toList(), const [], compareRingtoneCategories)),
        ['sivan', 'amman', 'ayyappan', 'murugan', 'perumal', 'others'],
      );
    });
  });

  group('a CMS order wins', () {
    test('wallpapers follow it exactly, Sivan included', () {
      expect(
        _slugs(
          orderedByCms(
            wallpapers.toList(),
            const ['amman', 'ayyappan', 'sivan', 'murugan', 'perumal', 'temples'],
            compareBrowseCategories,
          ),
        ),
        ['amman', 'ayyappan', 'sivan', 'murugan', 'perumal', 'temples'],
      );
    });

    test('`others` moves when dragged — the CMS is not overridden (owner call)', () {
      // The built-in rule pins `others` last on purpose. An explicit order is a
      // deliberate act, and silently ignoring it would leave the CMS showing one
      // order and the app another — the exact confusion this feature removes.
      expect(
        _slugs(
          orderedByCms(
            ringtones.toList(),
            const ['others', 'sivan', 'amman', 'ayyappan', 'murugan', 'perumal'],
            compareRingtoneCategories,
          ),
        ),
        ['others', 'sivan', 'amman', 'ayyappan', 'murugan', 'perumal'],
      );
    });
  });

  group('a PARTIAL order is ordinary, not an error', () {
    test('unlisted categories follow the listed ones, in the built-in order', () {
      // Published after the last drag: it must still appear, in its usual slot,
      // rather than vanishing or landing at a random index.
      final withRama = [...wallpapers, _cat('rama')];
      expect(
        _slugs(
          orderedByCms(withRama, const ['temples', 'murugan'], compareBrowseCategories),
        ),
        // listed first, in order… then the rest by Sivan-first-then-alphabetical.
        ['temples', 'murugan', 'sivan', 'amman', 'ayyappan', 'perumal', 'rama'],
      );
    });

    test('an order naming a category the catalog does not have adds nothing', () {
      // A category retracted or emptied in the CMS still has no chip: chips come
      // from published items, and this list only ever sorts what is already there.
      final only = [_cat('amman'), _cat('sivan')];
      expect(
        _slugs(
          orderedByCms(only, const ['rama', 'sivan', 'amman'], compareBrowseCategories),
        ),
        ['sivan', 'amman'],
      );
    });

    test('it never drops a category the order omits entirely', () {
      final result = orderedByCms(
        wallpapers.toList(),
        const ['temples'],
        compareBrowseCategories,
      );
      expect(result, hasLength(wallpapers.length));
      expect(_slugs(result).toSet(), _slugs(wallpapers).toSet());
    });
  });

  group('categoryOrderFor survives whatever the CDN hands it', () {
    test('reads one scope', () {
      expect(
        categoryOrderFor(const {
          'wallpapers': ['sivan', 'amman'],
          'ringtones': ['others'],
        }, 'wallpapers'),
        ['sivan', 'amman'],
      );
    });

    test('a null config, a missing scope and a wrong-typed value all read as none', () {
      // Any of these throwing would take the whole chip row down over a cosmetic field.
      expect(categoryOrderFor(null, 'wallpapers'), isEmpty);
      expect(categoryOrderFor(const {}, 'wallpapers'), isEmpty);
      expect(categoryOrderFor(const {'wallpapers': 'sivan'}, 'wallpapers'), isEmpty);
      expect(categoryOrderFor(const {'wallpapers': 42}, 'wallpapers'), isEmpty);
    });

    test('non-string and empty entries are dropped, not passed through', () {
      expect(
        categoryOrderFor(const {
          'wallpapers': ['sivan', 7, '', null, 'amman'],
        }, 'wallpapers'),
        ['sivan', 'amman'],
      );
    });
  });
}
