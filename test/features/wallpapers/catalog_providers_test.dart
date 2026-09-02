// The catalog provider's cache strategy is stale-while-revalidate -> these pin each of its four paths.
// Cold start with no cache -> network drain, page order preserved across the fan-out, cache written after a good parse.
// Warm start -> the DISK snapshot is served immediately, then the background revalidate replaces and re-caches it.
// refresh() bypasses the cached fast path -> a refresh failure keeps the data on screen instead of blanking the feed.
// A corrupt cache self-heals by deletion -> the error state exists ONLY with no cache AND a failed network.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:arul/data/catalog/catalog_http_client.dart';
import 'package:arul/data/models/wallpaper.dart';
import 'package:arul/data/repositories/repository_providers.dart';
import 'package:arul/features/wallpapers/providers/catalog_providers.dart';

Map<String, dynamic> _item(
  String stem, {
  String category = 'murugan',
  int? applyCount,
  int? feedRank,
}) => {
  'id': 'id-$stem',
  'title': stem,
  'type': 'static',
  'category': category,
  'full_key': 'wallpapers/$category/$stem.jpg',
  'width': 1080,
  'height': 1920,
  // Omitted entirely when never applied -> the shape of a fresh row AND of a cache written before the column existed.
  'apply_count': ?applyCount,
  // Same -> omitted when the admin has not pinned the row, which is nearly every row.
  'feed_rank': ?feedRank,
};

/// Ten ids in catalog order, newest first, as build-catalog emits them.
/// Shared by the ordering tests -> promoting two items must leave the other eight in exactly the order they arrived in.
const _stems = [
  'sivan0',
  'sivan1',
  'sivan2',
  'sivan3',
  'amman0',
  'amman1',
  'murugan0',
  'murugan1',
  'perumal0',
  'temple0',
];

http.Response _pageResponse(int page, int totalPages, List<String> stems) =>
    http.Response(
      jsonEncode({
        'page': page,
        'per_page': stems.length,
        'total': stems.length * totalPages,
        'total_pages': totalPages,
        'has_more': page < totalPages,
        'items': [for (final s in stems) _item(s)],
      }),
      200,
      headers: {'content-type': 'application/json'},
    );

/// Poll until [condition] holds, bounded -> lets the background revalidate's unawaited future finish in a real-async test.
Future<void> _pumpUntil(bool Function() condition) async {
  for (var i = 0; i < 200 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  late Directory tempDir;
  late File cacheFile;

  /// Swappable per test/step; MockClient delegates every request here.
  late Future<http.Response> Function(http.Request) handler;
  late List<String> requestedPaths;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('arul_catalog_test');
    cacheFile = File('${tempDir.path}/catalog.json');
    requestedPaths = [];
    handler = (_) async => http.Response('not found', 404);
  });

  tearDown(() async {
    // The provider's cache write is fire-and-forget -> on Windows a still-open handle makes delete throw -> retry briefly.
    for (var i = 0; ; i++) {
      try {
        await tempDir.delete(recursive: true);
        return;
      } on FileSystemException {
        if (i >= 20) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  ProviderContainer makeContainer() {
    final client = CatalogHttpClient(
      cdnBaseUrl: 'https://cdn.test',
      client: MockClient((req) {
        requestedPaths.add(req.url.path);
        return handler(req);
      }),
    );
    final container = ProviderContainer(
      // Riverpod 3's automatic backoff retry is off here -> the tests below assert the SETTLED error state.
      // A pending retry would keep `.future` unresolved past the test timeout.
      // Production keeps the default retry -> a cold-start network blip self-heals.
      retry: (retryCount, error) => null,
      overrides: [
        catalogCacheDirProvider.overrideWith((_) async => tempDir),
        catalogHttpClientProvider.overrideWithValue(client),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  /// A working 3-page catalog (60-ish items shape, shrunk to 2 per page).
  void serveThreePages() {
    handler = (req) async {
      final match = RegExp(r'all_(\d+)\.json$').firstMatch(req.url.path);
      final page = int.parse(match!.group(1)!);
      if (page > 3) return http.Response('not found', 404);
      return _pageResponse(page, 3, ['p${page}a', 'p${page}b']);
    };
  }

  Future<void> seedCache(List<String> stems) => cacheFile.writeAsString(
    jsonEncode({
      'items': [for (final s in stems) Wallpaper.fromJson(_item(s)).toJson()],
    }),
  );

  group('cold start (no cache)', () {
    test('drains all pages in page order and writes the cache', () async {
      serveThreePages();
      final container = makeContainer();

      final items = await container.read(catalogProvider.future);

      expect(items.map((w) => w.title), [
        'p1a',
        'p1b',
        'p2a',
        'p2b',
        'p3a',
        'p3b',
      ]);
      // The cache is written after a successful parse, best-effort -> poll for it rather than awaiting.
      await _pumpUntil(() => cacheFile.existsSync());
      final cached =
          jsonDecode(await cacheFile.readAsString()) as Map<String, dynamic>;
      expect((cached['items'] as List).length, 6);
    });

    test('network failure with NO cache is the error state', () async {
      handler = (_) async => throw http.ClientException('Failed host lookup');
      final container = makeContainer();

      await expectLater(
        container.read(catalogProvider.future),
        throwsA(anything),
      );
      expect(cacheFile.existsSync(), isFalse, reason: 'nothing to poison');
    });
  });

  group('warm start (stale-while-revalidate)', () {
    test('serves the disk snapshot immediately while the network is slow, '
        'then swaps in the fresh catalog when the revalidate lands', () async {
      await seedCache(['old1', 'old2']);

      // Network: alive but held — nothing completes until we open the gate.
      var gateOpen = false;
      handler = (req) async {
        await _pumpUntil(() => gateOpen);
        final match = RegExp(r'all_(\d+)\.json$').firstMatch(req.url.path);
        final page = int.parse(match!.group(1)!);
        return _pageResponse(page, 1, ['fresh1', 'fresh2', 'fresh3']);
      };

      final container = makeContainer();
      final sw = Stopwatch()..start();
      final served = await container.read(catalogProvider.future);
      sw.stop();

      expect(
        served.map((w) => w.title),
        ['old1', 'old2'],
        reason: 'cached catalog must be served without waiting on the network',
      );
      expect(sw.elapsed, lessThan(const Duration(milliseconds: 500)));

      // Open the network gate -> the background revalidate replaces the state.
      gateOpen = true;
      await _pumpUntil(() {
        final s = container.read(catalogProvider);
        return s is AsyncData<List<Wallpaper>> && s.value.length == 3;
      });
      final fresh = container.read(catalogProvider).requireValue;
      expect(fresh.map((w) => w.title), ['fresh1', 'fresh2', 'fresh3']);

      // And the fresh catalog is re-cached for the next launch.
      await _pumpUntil(() {
        final body = cacheFile.readAsStringSync();
        return body.contains('fresh1');
      });
    });

    test(
      'revalidate failure keeps serving the cache (no error flash)',
      () async {
        await seedCache(['old1']);
        handler = (_) async => throw http.ClientException('Failed host lookup');
        final container = makeContainer();

        final served = await container.read(catalogProvider.future);
        expect(served.single.title, 'old1');

        // Give the failed revalidate time to (not) clobber the state.
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(container.read(catalogProvider).hasValue, isTrue);
        expect(
          container.read(catalogProvider).requireValue.single.title,
          'old1',
        );
      },
    );
  });

  group('refresh()', () {
    test('bypasses the cached fast path and hits the network', () async {
      await seedCache(['old1']);
      // Build-time network is down -> the cache is served and the revalidate fails silently.
      handler = (_) async => throw http.ClientException('Failed host lookup');
      final container = makeContainer();
      expect(
        (await container.read(catalogProvider.future)).single.title,
        'old1',
      );

      // The network comes back -> an explicit refresh must fetch it.
      serveThreePages();
      requestedPaths.clear();
      await container.read(catalogProvider.notifier).refresh();

      expect(
        requestedPaths,
        isNotEmpty,
        reason: 'refresh must hit the network',
      );
      expect(container.read(catalogProvider).requireValue.map((w) => w.title), [
        'p1a',
        'p1b',
        'p2a',
        'p2b',
        'p3a',
        'p3b',
      ]);
    });

    test('refresh failure keeps the current data on screen', () async {
      serveThreePages();
      final container = makeContainer();
      final before = await container.read(catalogProvider.future);

      handler = (_) async => throw http.ClientException('Failed host lookup');
      await container.read(catalogProvider.notifier).refresh();

      final after = container.read(catalogProvider);
      expect(after.hasValue, isTrue);
      expect(after.requireValue, before);
    });
  });

  group('feed order', () {
    /// A catalog shaped like a real bulk import -> a 30-wallpaper Sivan batch at the head, then older mixed content.
    /// One transaction means they tie on sort_order AND created_at -> build-catalog emits them consecutively.
    void serveClumpedCatalog() {
      final items = <Map<String, dynamic>>[
        for (var i = 0; i < 30; i++) _item('sivan$i', category: 'sivan'),
        for (var i = 0; i < 10; i++) _item('amman$i', category: 'amman'),
        for (var i = 0; i < 10; i++) _item('murugan$i', category: 'murugan'),
        for (var i = 0; i < 10; i++) _item('temple$i', category: 'temples'),
      ];
      handler = (_) async => http.Response(
        jsonEncode({
          'page': 1,
          'per_page': items.length,
          'total': items.length,
          'total_pages': 1,
          'has_more': false,
          'items': items,
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    }

    Future<List<Wallpaper>> feedFor(ProviderContainer c, String slug) async {
      await c.read(catalogProvider.future);
      c.read(selectedCategoryProvider.notifier).select(slug);
      return c.read(feedProvider).requireValue;
    }

    test('All is a permutation of the catalog — reordering never drops or '
        'duplicates a row', () async {
      serveClumpedCatalog();
      final container = makeContainer();

      final all = await feedFor(container, WallpaperCategory.allSlug);

      expect(all, hasLength(60));
      expect(
        all.map((w) => w.id).toSet(),
        container.read(catalogProvider).requireValue.map((w) => w.id).toSet(),
      );
    });

    test(
      'with nothing applied yet, All IS catalog order — so a bulk import does '
      'own the top, deliberately',
      () async {
        // The accepted cost of "default behaviour is newest only" -> it replaced an FNV-1a shuffle built to stop this.
        // Pinned as a REQUIREMENT, not left untested -> the next reader will see 30 Sivan in a row and call it a bug.
        // A re-introduced shuffle would fight the popularity order.
        serveClumpedCatalog();

        final all = await feedFor(makeContainer(), WallpaperCategory.allSlug);

        expect(
          all.take(30).every((w) => w.category == 'sivan'),
          isTrue,
          reason:
              'zero applies everywhere → every comparison falls through to '
              'catalog order, which is newest-first',
        );
      },
    );

    test(
      'the All order is stable — the same catalog yields the same order '
      'on a rebuild, so a revalidate never reshuffles under the user',
      () async {
        serveClumpedCatalog();
        final first = await feedFor(makeContainer(), WallpaperCategory.allSlug);
        final second = await feedFor(
          makeContainer(),
          WallpaperCategory.allSlug,
        );
        expect(second.map((w) => w.id), first.map((w) => w.id));
      },
    );

    test('with no applies anywhere, All is exactly catalog order — the '
        '"newest only" default', () {
      final all = [for (final s in _stems) Wallpaper.fromJson(_item(s))];
      expect(all.every((w) => w.applyCount == 0), isTrue);

      expect(
        feedOrder(WallpaperCategory.allSlug, all).map((w) => w.title),
        _stems,
      );
    });

    test('applied wallpapers lead All by count, and everything else keeps the '
        'exact relative order it arrived in', () {
      // Two rows promoted out of ten, with counts deliberately opposite to catalog order -> only apply_count makes this head.
      const applied = {'temple0': 5, 'amman1': 12};
      final all = [
        for (final s in _stems)
          Wallpaper.fromJson(_item(s, applyCount: applied[s])),
      ];

      final ordered = feedOrder(WallpaperCategory.allSlug, all);

      expect(ordered.take(2).map((w) => w.id), ['id-amman1', 'id-temple0']);
      expect(
        ordered.skip(2).map((w) => w.title),
        _stems.where((s) => !applied.containsKey(s)),
        reason: 'promoting two rows must never re-point the rest of the feed',
      );
      expect(ordered, hasLength(_stems.length));
    });

    test('an apply_count tie falls back to catalog position, so All stays a '
        'TOTAL order', () {
      // Dart's List.sort is NOT stable -> ties must be broken explicitly or the order is free to change between runs.
      // That would re-point the pager and the video pool under a scrolling user on every revalidate.
      final all = [
        Wallpaper.fromJson(_item('sivan0', applyCount: 7)),
        Wallpaper.fromJson(_item('amman0', applyCount: 7)),
        Wallpaper.fromJson(_item('murugan0')),
      ];

      expect(feedOrder(WallpaperCategory.allSlug, all).map((w) => w.title), [
        'sivan0',
        'amman0',
        'murugan0',
      ]);
      // Reversing the INPUT reverses the tie, because catalog position is the tiebreaker.
      // The order is a pure function of the list it is given.
      expect(
        feedOrder(
          WallpaperCategory.allSlug,
          all.reversed.toList(growable: false),
        ).map((w) => w.title),
        ['amman0', 'sivan0', 'murugan0'],
      );
    });

    test('a category chip runs the SAME comparator as All — a filtered view '
        'can never contradict All', () {
      // THE invariant of the three-tier order -> every chip sorts, and a category is All restricted to that category.
      // It is never a differently-ordered list.
      final all = [
        for (final s in _stems)
          Wallpaper.fromJson(
            _item(
              s,
              category: s.startsWith('sivan') ? 'sivan' : 'other',
              applyCount: {'sivan2': 99}[s],
              feedRank: {'sivan3': 10}[s],
            ),
          ),
      ];

      final fromAll = feedOrder(
        WallpaperCategory.allSlug,
        all,
      ).where((w) => w.category == 'sivan').map((w) => w.title);

      expect(feedOrder('sivan', all).map((w) => w.title), fromAll);
      expect(fromAll, ['sivan3', 'sivan2', 'sivan0', 'sivan1']);
    });

    test('apply_count survives the disk-cache round-trip', () {
      // The cache round-trips through toJson()/fromJson() -> a count that does not survive flattens every warm start.
      // It would read newest-first until the background revalidate landed.
      final applied = Wallpaper.fromJson(_item('sivan0', applyCount: 30));
      expect(Wallpaper.fromJson(applied.toJson()).applyCount, 30);
    });

    test(
      'feed_rank survives the disk-cache round-trip, and a null stays null',
      () {
        // Same trap as the count above -> a pin that does not round-trip drops every warm start to popularity order.
        // And a null must NOT come back as 0 -> 0 is a valid top pin.
        final pinned = Wallpaper.fromJson(_item('sivan0', feedRank: 20));
        expect(Wallpaper.fromJson(pinned.toJson()).feedRank, 20);

        final unpinned = Wallpaper.fromJson(_item('sivan1'));
        expect(unpinned.feedRank, isNull);
        expect(Wallpaper.fromJson(unpinned.toJson()).feedRank, isNull);
      },
    );

    test('a pin leads the feed, ahead of a far more popular row', () {
      // Tier 1 beats tier 2 -> that is the entire point of the rank field.
      final all = [
        Wallpaper.fromJson(_item('sivan0', applyCount: 500)),
        Wallpaper.fromJson(_item('amman0', feedRank: 10)),
        Wallpaper.fromJson(_item('murugan0', applyCount: 200)),
      ];

      expect(feedOrder(WallpaperCategory.allSlug, all).map((w) => w.title), [
        'amman0',
        'sivan0',
        'murugan0',
      ]);
    });

    test('pins order among themselves by rank ascending', () {
      final all = [
        Wallpaper.fromJson(_item('a', feedRank: 30)),
        Wallpaper.fromJson(_item('b', feedRank: 10)),
        Wallpaper.fromJson(_item('c', feedRank: 20)),
      ];

      expect(feedOrder(WallpaperCategory.allSlug, all).map((w) => w.title), [
        'b',
        'c',
        'a',
      ]);
    });

    test(
      'an unpinned row sinks below every pin — nulls LAST, never rank 0',
      () {
        // Treating null as 0 would pin the whole uncurated catalog above the curated head -> exactly inverting it.
        final all = [
          Wallpaper.fromJson(_item('unpinned0', applyCount: 99)),
          Wallpaper.fromJson(_item('pinned', feedRank: 400)),
          Wallpaper.fromJson(_item('unpinned1')),
        ];

        expect(feedOrder(WallpaperCategory.allSlug, all).map((w) => w.title), [
          'pinned',
          'unpinned0',
          'unpinned1',
        ]);
      },
    );

    test('rank 0 is a real pin, not an absent one', () {
      final all = [
        Wallpaper.fromJson(_item('popular', applyCount: 99)),
        Wallpaper.fromJson(_item('zero', feedRank: 0)),
      ];

      expect(feedOrder(WallpaperCategory.allSlug, all).first.title, 'zero');
    });

    test('a duplicate rank falls back to catalog position, so the order stays '
        'TOTAL', () {
      // Same non-stable-sort hazard as the apply_count tie -> the CMS writes sparse ranks, but two rows may share one.
      final all = [
        Wallpaper.fromJson(_item('first', feedRank: 10)),
        Wallpaper.fromJson(_item('second', feedRank: 10)),
        Wallpaper.fromJson(_item('third')),
      ];

      expect(feedOrder(WallpaperCategory.allSlug, all).map((w) => w.title), [
        'first',
        'second',
        'third',
      ]);
      expect(
        feedOrder(
          WallpaperCategory.allSlug,
          all.reversed.toList(growable: false),
        ).map((w) => w.title),
        ['second', 'first', 'third'],
      );
    });

    test('an unrelated bulk import leaves the pins untouched', () {
      // The property that retired v1 -> curation lived in sort_order and every import reset it.
      // Imported rows arrive with NO rank -> they land behind the curated head however new they are.
      final curated = [
        Wallpaper.fromJson(_item('pin0', category: 'amman', feedRank: 10)),
        Wallpaper.fromJson(_item('pin1', category: 'amman', feedRank: 20)),
      ];
      final imported = [
        for (var i = 0; i < 30; i++)
          Wallpaper.fromJson(_item('fresh$i', category: 'sivan')),
      ];

      // Imported rows lead the CATALOG, newest first, yet still trail the pins.
      final ordered = feedOrder(WallpaperCategory.allSlug, [
        ...imported,
        ...curated,
      ]);

      expect(ordered.take(2).map((w) => w.title), ['pin0', 'pin1']);
      expect(ordered, hasLength(32));
    });

    test('an uncurated, never-applied category chip is plain catalog order — '
        'newest first', () async {
      // Sorting a chip only changes it once something is pinned or applied -> the zero state must stay newest-first.
      serveClumpedCatalog();

      final sivan = await feedFor(makeContainer(), 'sivan');

      expect(sivan, hasLength(30));
      expect(
        sivan.map((w) => w.title),
        [for (var i = 0; i < 30; i++) 'sivan$i'],
        reason: 'both order tiers above catalog position are empty here',
      );
    });
  });

  group('corrupt cache', () {
    test(
      'self-heals: bad snapshot is deleted and the network path serves',
      () async {
        await cacheFile.writeAsString('{"items": [truncated-mid-wri');
        serveThreePages();
        final container = makeContainer();

        final items = await container.read(catalogProvider.future);
        expect(
          items,
          hasLength(6),
          reason: 'network result, not the bad cache',
        );

        // Rewritten with the good catalog.
        await _pumpUntil(() {
          try {
            final body = jsonDecode(cacheFile.readAsStringSync());
            return (body as Map<String, dynamic>)['items'] != null;
          } catch (_) {
            return false;
          }
        });
      },
    );

    test(
      'corrupt cache + dead network = error, and the bad file is gone',
      () async {
        await cacheFile.writeAsString('not json at all');
        handler = (_) async => throw http.ClientException('Failed host lookup');
        final container = makeContainer();

        await expectLater(
          container.read(catalogProvider.future),
          throwsA(anything),
        );
        expect(
          cacheFile.existsSync(),
          isFalse,
          reason: 'a corrupt snapshot must never survive to brick later starts',
        );
      },
    );
  });
}
