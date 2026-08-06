// The Ringtones chip row's ORDER.
//
// Ringtone categories are not the wallpaper ones: the five deities plus
// `others`, the bucket for tracks belonging to none of them (Hanuman, Ganesha,
// the Madhwa guru Raghavendra). Sorted plainly by label, "Others" lands between
// "Murugan" and "Perumal" and reads as one more deity — so it is pinned last.
// That is a contract, not a cosmetic choice, and nothing else in the app would
// catch it regressing.

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

  test('others sorts last, everything else alphabetically', () {
    expect(
      _ordered([
        cat('perumal'),
        cat('others'),
        cat('amman'),
        cat('murugan'),
        cat('sivan'),
        cat('ayyappan'),
      ]),
      ['Amman', 'Ayyappan', 'Murugan', 'Perumal', 'Sivan', 'Others'],
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
      expect(
        _ordered(rotated.map(cat).toList()).last,
        'Others',
        reason: 'rotation starting at ${slugs[i]}',
      );
    }
  });

  test('a category row with no others is plain alphabetical', () {
    expect(_ordered([cat('sivan'), cat('amman'), cat('murugan')]), [
      'Amman',
      'Murugan',
      'Sivan',
    ]);
  });

  test('others alone is fine', () {
    expect(_ordered([cat('others')]), ['Others']);
  });
}
