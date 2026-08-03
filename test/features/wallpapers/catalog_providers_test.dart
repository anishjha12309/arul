// Tests for the catalog provider's cache strategy (stale-while-revalidate):
//   - cold start (no cache): network drain, page order preserved across the
//     bounded-concurrency fan-out, cache written after a successful parse.
//   - warm start: the DISK snapshot is served immediately even while the
//     network is still in flight, then the fresh catalog replaces it when the
//     background revalidate lands (and is re-cached).
//   - refresh(): bypasses the cached fast path (real network), and a refresh
//     failure keeps the data on screen instead of blanking the feed.
//   - corrupt cache: self-heals (deleted) and falls through to the network;
//     the error state exists ONLY when there is no cache AND the network fails.

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
  int? feedRank,
}) => {
  'id': 'id-$stem',
  'title': stem,
  'type': 'static',
  'category': category,
  'full_key': 'wallpapers/$category/$stem.jpg',
  'width': 1080,
  'height': 1920,
  // Omitted entirely when uncurated — the shape of a real uncurated row AND of
  // a catalog cached by a build that predates the column.
  'feed_rank': ?feedRank,
};

/// The golden-pin catalog: ten ids whose FNV-1a permutation is pinned in
/// [_pinOrder]. Shared by the pin test and the curation tests, so the latter can
/// assert that curating two items leaves the other eight exactly where they were.
const _pinStems = [
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

/// The All order [_pinStems] must produce while nothing is curated.
const _pinOrder = [
  'id-murugan0',
  'id-murugan1',
  'id-temple0',
  'id-sivan2',
  'id-perumal0',
  'id-sivan3',
  'id-amman1',
  'id-sivan0',
  'id-amman0',
  'id-sivan1',
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

/// Poll until [condition] holds (bounded) — lets the background revalidate's
/// unawaited future run to completion in real-async tests.
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
    // The provider's cache write is fire-and-forget; on Windows a still-open
    // handle makes delete throw. Retry briefly instead of failing the test.
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
      // Disable Riverpod 3's automatic exponential-backoff retry: the tests
      // below assert the SETTLED error state, and a pending retry would keep
      // `.future` unresolved past the test timeout. Production keeps the
      // default retry (a cold-start network blip self-heals, mirroring the
      // reference feed's initial-load backoffs).
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
      // Cache written after the successful parse (best-effort, so poll).
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

      // Open the network gate → the background revalidate replaces the state.
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
      // Build-time network is down → cache served, revalidate fails silently.
      handler = (_) async => throw http.ClientException('Failed host lookup');
      final container = makeContainer();
      expect(
        (await container.read(catalogProvider.future)).single.title,
        'old1',
      );

      // Network comes back; an explicit refresh must fetch it.
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
    /// A catalog shaped like a real bulk import: a 30-wallpaper Sivan batch at
    /// the head (one transaction, so they tie on sort_order AND created_at and
    /// build-catalog emits them consecutively), then older mixed content.
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

    test(
      'All breaks a bulk import up instead of letting it own the top',
      () async {
        serveClumpedCatalog();
        final container = makeContainer();

        final all = await feedFor(container, WallpaperCategory.allSlug);

        // A permutation of the catalog: reordering must never drop or duplicate.
        expect(all, hasLength(60));
        expect(
          all.map((w) => w.id).toSet(),
          container.read(catalogProvider).requireValue.map((w) => w.id).toSet(),
        );
        // The defect: all 30 of one import sitting in the first 30 slots.
        expect(
          all.take(30).where((w) => w.category == 'sivan').length,
          lessThan(25),
        );
        expect(
          all.take(10).map((w) => w.category).toSet(),
          hasLength(greaterThan(1)),
          reason: 'the first screenful is not one category',
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

    test('golden pin: with nothing curated, All is this exact permutation for '
        'these ids, regardless of arrival order', () {
      // The stability tests above prove same-runtime determinism, but they
      // would still pass if _fnv1a were swapped for String.hashCode — the
      // exact regression the hand-rolled hash exists to prevent (its output
      // is not contractually stable across Dart releases). Pinning the
      // literal permutation guards the other half of the contract: if this
      // fails, the hash changed, and the All feed silently re-orders under
      // every existing install on the next app upgrade.
      //
      // Since none of these items carries a feed_rank, this ALSO pins the
      // curated head's shipped state: no curation must mean no change at all.
      final all = [for (final s in _pinStems) Wallpaper.fromJson(_item(s))];
      expect(all.every((w) => w.feedRank == null), isTrue);

      final ordered = feedOrder(WallpaperCategory.allSlug, all);

      expect(ordered.map((w) => w.id).toList(), _pinOrder);

      // Pure function of catalog CONTENT: the rows arriving in a different
      // order must not change the served order.
      final fromReversed = feedOrder(
        WallpaperCategory.allSlug,
        all.reversed.toList(growable: false),
      );
      expect(fromReversed.map((w) => w.id), ordered.map((w) => w.id));
    });

    test('a curated block leads All in feed_rank order, and the uncurated '
        'tail keeps the exact order it had before curation', () {
      // Two heroes pinned out of the ten. The ranks are sparse (the CMS writes
      // 10, 20, 30 …) and deliberately opposite to both id order and the
      // shuffle's — only feed_rank can produce this head.
      const ranks = {'sivan1': 10, 'amman0': 20};
      final all = [
        for (final s in _pinStems)
          Wallpaper.fromJson(_item(s, feedRank: ranks[s])),
      ];

      final ordered = feedOrder(WallpaperCategory.allSlug, all);

      expect(ordered.take(2).map((w) => w.id), ['id-sivan1', 'id-amman0']);
      expect(
        ordered.skip(2).map((w) => w.id),
        _pinOrder.where((id) => !const {'id-sivan1', 'id-amman0'}.contains(id)),
        reason: 'curating two items must never re-point the rest of the feed',
      );
      expect(ordered, hasLength(_pinStems.length));
    });

    test('a feed_rank tie falls back to id, so the curated head stays a '
        'TOTAL order however the rows arrived', () {
      final all = [
        Wallpaper.fromJson(_item('sivan0', feedRank: 10)),
        Wallpaper.fromJson(_item('amman0', feedRank: 10)),
        Wallpaper.fromJson(_item('murugan0')),
      ];
      const expected = ['id-amman0', 'id-sivan0', 'id-murugan0'];

      expect(
        feedOrder(WallpaperCategory.allSlug, all).map((w) => w.id),
        expected,
      );
      expect(
        feedOrder(
          WallpaperCategory.allSlug,
          all.reversed.toList(growable: false),
        ).map((w) => w.id),
        expected,
      );
    });

    test(
      'a category chip ignores feed_rank entirely — it stays catalog order',
      () {
        final all = [
          Wallpaper.fromJson(_item('sivan0', category: 'sivan')),
          Wallpaper.fromJson(_item('sivan1', category: 'sivan', feedRank: 10)),
          Wallpaper.fromJson(_item('sivan2', category: 'sivan')),
        ];

        expect(feedOrder('sivan', all).map((w) => w.title), [
          'sivan0',
          'sivan1',
          'sivan2',
        ]);
      },
    );

    test('feed_rank survives the disk-cache round-trip', () {
      // The cache is written as toJson() and read back as fromJson(), so a
      // rank that does not round-trip would silently un-curate every warm
      // start until the background revalidate landed.
      final curated = Wallpaper.fromJson(_item('sivan0', feedRank: 30));
      expect(Wallpaper.fromJson(curated.toJson()).feedRank, 30);
    });

    test('a category chip keeps catalog order — newest first', () async {
      serveClumpedCatalog();

      final sivan = await feedFor(makeContainer(), 'sivan');

      expect(sivan, hasLength(30));
      expect(
        sivan.map((w) => w.title),
        [for (var i = 0; i < 30; i++) 'sivan$i'],
        reason: 'catalog order, untouched by the All shuffle',
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
