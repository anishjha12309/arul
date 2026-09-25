// Ringtone categories are NOT the wallpaper ones -> the five deities plus `others` for tracks belonging to none.
// Sorted plainly by label, "Others" lands between "Murugan" and "Perumal" and reads as one more deity -> pin it LAST.
// Sivan is pinned FIRST (owner's instruction) -> the same rule the wallpaper chip row runs.
// Both are contracts, not cosmetic choices -> nothing else in the app would catch either regressing.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arul/data/models/ringtone.dart';
import 'package:arul/data/models/wallpaper.dart';
import 'package:arul/data/repositories/repository_providers.dart';
import 'package:arul/features/ringtones/providers/ringtone_catalog_providers.dart';

class _FakeCatalog extends RingtoneCatalogNotifier {
  _FakeCatalog(this._items);
  final List<Ringtone> _items;
  @override
  Future<List<Ringtone>> build() async => _items;
}

List<String> _ordered(List<WallpaperCategory> input) =>
    (input.toList()..sort(compareRingtoneCategories))
        .map((c) => c.label)
        .toList();

void main() {
  WallpaperCategory cat(String slug) =>
      WallpaperCategory(slug, slug[0].toUpperCase() + slug.substring(1));

  test('sivan sorts first, others last, the rest alphabetically', () {
    expect(
      _ordered([
        cat('perumal'),
        cat('others'),
        cat('amman'),
        cat('murugan'),
        cat('sivan'),
        cat('ayyappan'),
      ]),
      ['Sivan', 'Amman', 'Ayyappan', 'Murugan', 'Perumal', 'Others'],
    );
  });

  test('others stays last however the input is ordered', () {
    final slugs = [
      'amman',
      'ayyappan',
      'murugan',
      'others',
      'perumal',
      'sivan',
    ];
    // Every rotation of the same set must land on the same order.
    for (var i = 0; i < slugs.length; i++) {
      final rotated = [...slugs.sublist(i), ...slugs.sublist(0, i)];
      final ordered = _ordered(rotated.map(cat).toList());
      expect(
        ordered.last,
        'Others',
        reason: 'rotation starting at ${slugs[i]}',
      );
      expect(
        ordered.first,
        'Sivan',
        reason: 'rotation starting at ${slugs[i]}',
      );
    }
  });

  test('a category row with no others still leads with sivan', () {
    expect(_ordered([cat('amman'), cat('murugan'), cat('sivan')]), [
      'Sivan',
      'Amman',
      'Murugan',
    ]);
  });

  test('a row without sivan is plain alphabetical, others last', () {
    expect(_ordered([cat('perumal'), cat('others'), cat('amman')]), [
      'Amman',
      'Perumal',
      'Others',
    ]);
  });

  test('others alone is fine', () {
    expect(_ordered([cat('others')]), ['Others']);
  });

  test(
    'the retired others category is never offered, even with a stray row',
    () async {
      Ringtone tone(String id, String category) =>
          Ringtone(id: id, title: id, category: category, audioKey: '$id.mp3');
      final container = ProviderContainer(
        overrides: [
          ringtoneCatalogProvider.overrideWith(
            () => _FakeCatalog([tone('a', 'murugan'), tone('b', 'others')]),
          ),
          appConfigProvider.overrideWithBuild((ref, _) async => null),
        ],
      );
      addTearDown(container.dispose);
      await container.read(ringtoneCatalogProvider.future);
      await container.read(appConfigProvider.future);
      expect(container.read(ringtoneCategoriesProvider).map((c) => c.slug), [
        'murugan',
      ]);
    },
  );
}
