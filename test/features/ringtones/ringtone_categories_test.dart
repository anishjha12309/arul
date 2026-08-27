// The Ringtones chip row's ORDER.
//
// Ringtone categories are not the wallpaper ones: the five deities plus
// `others`, the bucket for tracks belonging to none of them (Hanuman, Ganesha,
// the Madhwa guru Raghavendra). Sorted plainly by label, "Others" lands between
// "Murugan" and "Perumal" and reads as one more deity — so it is pinned last.
// Sivan is pinned FIRST (owner's instruction 2026-08-27), the same rule the
// wallpaper row runs. Both are contracts, not cosmetic choices, and nothing
// else in the app would catch either regressing.

import 'package:flutter_test/flutter_test.dart';

import 'package:arul/data/models/wallpaper.dart';
import 'package:arul/features/ringtones/providers/ringtone_catalog_providers.dart';

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
}
