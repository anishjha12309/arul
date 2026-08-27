// The wallpaper chip row's ORDER.
//
// Sivan leads the row, right after the All chip (owner's instruction
// 2026-08-27); every other category follows alphabetically. Chip order only —
// the items inside a chip keep their merit order (CLAUDE.md §5b), so this can
// never contradict All.

import 'package:flutter_test/flutter_test.dart';

import 'package:arul/data/models/wallpaper.dart';

List<String> _ordered(List<WallpaperCategory> input) =>
    (input.toList()..sort(compareBrowseCategories))
        .map((c) => c.label)
        .toList();

void main() {
  WallpaperCategory cat(String slug) =>
      WallpaperCategory(slug, slug[0].toUpperCase() + slug.substring(1));

  test('sivan leads, the rest alphabetically', () {
    expect(
      _ordered([
        cat('perumal'),
        cat('temples'),
        cat('amman'),
        cat('murugan'),
        cat('sivan'),
        cat('ayyappan'),
      ]),
      ['Sivan', 'Amman', 'Ayyappan', 'Murugan', 'Perumal', 'Temples'],
    );
  });

  test('sivan leads however the input is ordered', () {
    final slugs = [
      'amman',
      'ayyappan',
      'murugan',
      'perumal',
      'sivan',
      'temples',
    ];
    for (var i = 0; i < slugs.length; i++) {
      final rotated = [...slugs.sublist(i), ...slugs.sublist(0, i)];
      expect(
        _ordered(rotated.map(cat).toList()).first,
        'Sivan',
        reason: 'rotation starting at ${slugs[i]}',
      );
    }
  });

  test('a row without sivan is plain alphabetical', () {
    expect(_ordered([cat('temples'), cat('amman'), cat('murugan')]), [
      'Amman',
      'Murugan',
      'Temples',
    ]);
  });
}
