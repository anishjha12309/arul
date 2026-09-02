// The Ringtones tab's ORDER -> the same three tiers the wallpaper feed serves (CLAUDE.md §5b).
// feed_rank ASC nulls-last -> set_count DESC -> catalog position.
// Both tabs share ONE comparator (orderedByUse) so they cannot drift, but reach it through separate providers.
// That wiring breaks silently -> a list that forgets `rank:`, or a chip that skips the sort, compiles and renders fine.
// The tier logic is proven in test/features/wallpapers/catalog_providers_test.dart -> pinned here is that this tab uses it.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arul/data/models/ringtone.dart';
import 'package:arul/data/models/wallpaper.dart';
import 'package:arul/features/ringtones/providers/ringtone_catalog_providers.dart';

class _FakeCatalog extends RingtoneCatalogNotifier {
  _FakeCatalog(this._items);
  final List<Ringtone> _items;
  @override
  Future<List<Ringtone>> build() async => _items;
}

Ringtone _rt(
  String id, {
  String category = 'murugan',
  int setCount = 0,
  int? feedRank,
}) => Ringtone(
  id: id,
  title: id,
  category: category,
  audioKey: '$id.mp3',
  setCount: setCount,
  feedRank: feedRank,
);

void main() {
  Future<List<String>> feed(List<Ringtone> catalog, String slug) async {
    final container = ProviderContainer(
      overrides: [
        ringtoneCatalogProvider.overrideWith(() => _FakeCatalog(catalog)),
      ],
    );
    addTearDown(container.dispose);
    await container.read(ringtoneCatalogProvider.future);
    container.read(selectedRingtoneCategoryProvider.notifier).select(slug);
    return container
        .read(ringtoneFeedProvider)
        .requireValue
        .map((r) => r.id)
        .toList();
  }

  test('a pin leads the list, ahead of a far more-set track', () async {
    final catalog = [
      _rt('popular', setCount: 500),
      _rt('pinned', feedRank: 10),
      _rt('middling', setCount: 200),
    ];

    expect(await feed(catalog, WallpaperCategory.allSlug), [
      'pinned',
      'popular',
      'middling',
    ]);
  });

  test('an unpinned track sinks below every pin — nulls LAST', () async {
    // A null rank read as 0 would put the whole uncurated catalog above the curated head.
    // Ringtones start with every rank null -> this is the live shape on day one, not an edge case.
    final catalog = [
      _rt('unpinned', setCount: 99),
      _rt('pinned', feedRank: 400),
    ];

    expect(await feed(catalog, WallpaperCategory.allSlug), [
      'pinned',
      'unpinned',
    ]);
  });

  test(
    'a category chip runs the same comparator — it cannot contradict All',
    () async {
      final catalog = [
        _rt('m0', category: 'murugan'),
        _rt('m1', category: 'murugan', setCount: 40),
        _rt('s0', category: 'sivan', feedRank: 10),
        _rt('m2', category: 'murugan', feedRank: 20),
      ];

      final all = await feed(catalog, WallpaperCategory.allSlug);
      expect(all, ['s0', 'm2', 'm1', 'm0']);
      expect(
        await feed(catalog, 'murugan'),
        all.where((id) => id.startsWith('m')),
      );
    },
  );

  test(
    'with nothing pinned and nothing set, the list IS catalog order',
    () async {
      // The zero state is the intended default, not a fallback -> every comparison falls through to catalog position.
      // build-catalog already emits that order -> nothing client-side re-derives it.
      final catalog = [
        _rt('a', category: 'amman'),
        _rt('b', category: 'sivan'),
        _rt('c', category: 'others'),
      ];

      expect(await feed(catalog, WallpaperCategory.allSlug), ['a', 'b', 'c']);
    },
  );
}
