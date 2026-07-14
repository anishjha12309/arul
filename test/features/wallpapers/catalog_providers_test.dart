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

Map<String, dynamic> _item(String stem, {String category = 'murugan'}) => {
  'id': 'id-$stem',
  'title': stem,
  'type': 'static',
  'category': category,
  'full_key': 'wallpapers/$category/$stem.jpg',
  'width': 1080,
  'height': 1920,
};

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
