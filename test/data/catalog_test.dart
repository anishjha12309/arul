// Tests for the Worker-catalog data layer:
//   - Wallpaper: snake_case parse of the Worker catalog item (incl. the Arul
//     `category` delta), kind mapping, and the CRITICAL thumb derivation —
//     thumbs/<category>/<file-stem>.jpg from full_key, NEVER from the DB id.
//   - CatalogPage.fromJson envelope parsing.
//   - CatalogHttpClient: ?v= stamping via CatalogVersion, null on CDN miss,
//     NetworkException on connectivity failure.

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:arul/core/error/app_exception.dart';
import 'package:arul/data/catalog/catalog_http_client.dart';
import 'package:arul/data/catalog/catalog_version.dart';
import 'package:arul/data/models/catalog_page.dart';
import 'package:arul/data/models/wallpaper.dart';

Map<String, dynamic> _item({
  String id = 'a2b4c6d8-0000-0000-0000-000000000000',
  String type = 'live',
  String category = 'murugan',
  String fullKey = 'wallpapers/murugan/95b5276e.mp4',
}) => {
  'id': id,
  'title': 'Murugan',
  'type': type,
  'tags': <String>[],
  'category': category,
  'full_key': fullKey,
  'width': 1024,
  'height': 1824,
  'is_published': true,
  'sort_order': 0,
};

void main() {
  group('Wallpaper.fromJson (Worker catalog item)', () {
    test('parses snake_case fields including the Arul category delta', () {
      final w = Wallpaper.fromJson(_item());
      expect(w.id, 'a2b4c6d8-0000-0000-0000-000000000000');
      expect(w.title, 'Murugan');
      expect(w.category, 'murugan');
      expect(w.categoryLabel, 'Murugan');
      expect(w.kind, WallpaperKind.live);
      expect(w.key, 'wallpapers/murugan/95b5276e.mp4');
      expect(w.width, 1024);
      expect(w.height, 1824);
    });

    test("type 'static' maps to WallpaperKind.image", () {
      expect(
        Wallpaper.fromJson(_item(type: 'static')).kind,
        WallpaperKind.image,
      );
    });

    test('missing category falls back without crashing (edge-cases.md)', () {
      final json = _item()..remove('category');
      expect(Wallpaper.fromJson(json).category, 'other');
    });

    test('url() joins the CDN base with the R2 key', () {
      expect(
        Wallpaper.fromJson(_item()).url('https://cdn.test'),
        'https://cdn.test/wallpapers/murugan/95b5276e.mp4',
      );
    });

    test('thumbUrl derives from the FULL-KEY STEM, never from the DB id', () {
      final w = Wallpaper.fromJson(_item());
      final thumb = w.thumbUrl('https://cdn.test');
      expect(thumb, 'https://cdn.test/thumbs/murugan/95b5276e.jpg');
      expect(
        thumb.contains(w.id),
        isFalse,
        reason: 'the Worker catalog id is a DB UUID unrelated to thumb names',
      );
    });

    test('toJson round-trips through fromJson (disk-cache contract)', () {
      final w = Wallpaper.fromJson(_item(type: 'static'));
      final again = Wallpaper.fromJson(w.toJson());
      expect(again, w);
    });
  });

  group('CatalogPage.fromJson', () {
    test('parses the page envelope and items', () {
      final page = CatalogPage.fromJson({
        'page': 2,
        'per_page': 20,
        'total': 45,
        'total_pages': 3,
        'has_more': true,
        'items': [_item()],
      }, Wallpaper.fromJson);
      expect(page.page, 2);
      expect(page.perPage, 20);
      expect(page.total, 45);
      expect(page.totalPages, 3);
      expect(page.hasMore, isTrue);
      expect(page.items.single.category, 'murugan');
    });

    test('defaults for a missing envelope', () {
      final page = CatalogPage.fromJson(
        <String, dynamic>{},
        Wallpaper.fromJson,
      );
      expect(page.items, isEmpty);
      expect(page.hasMore, isFalse);
    });
  });

  group('CatalogHttpClient', () {
    http.Response json(String body) =>
        http.Response(body, 200, headers: {'content-type': 'application/json'});

    test(
      'stamps every page fetch with ?v= from version.json (no-store)',
      () async {
        final urls = <String>[];
        final mock = MockClient((req) async {
          urls.add(req.url.toString());
          if (req.url.path.endsWith('version.json')) {
            return json('{"content_version": "42"}');
          }
          return json(
            '{"page":1,"per_page":20,"total":1,"total_pages":1,"has_more":false,'
            '"items":[]}',
          );
        });
        final client = CatalogHttpClient(
          cdnBaseUrl: 'https://cdn.test',
          client: mock,
          version: CatalogVersion(cdnBaseUrl: 'https://cdn.test', client: mock),
        );

        final page = await client.fetchPage(
          scope: 'wallpapers',
          slug: 'all',
          page: 1,
          itemFromJson: Wallpaper.fromJson,
        );

        expect(page, isNotNull);
        expect(urls.first, 'https://cdn.test/catalog/version.json');
        expect(
          urls.last,
          'https://cdn.test/catalog/wallpapers/all_1.json?v=42',
        );
      },
    );

    test('CDN miss (404) returns null, not an exception', () async {
      final client = CatalogHttpClient(
        cdnBaseUrl: 'https://cdn.test',
        client: MockClient((_) async => http.Response('not found', 404)),
      );
      final page = await client.fetchPage(
        scope: 'wallpapers',
        slug: 'all',
        page: 99,
        itemFromJson: Wallpaper.fromJson,
      );
      expect(page, isNull);
    });

    test('connectivity failure throws NetworkException (retry UX)', () async {
      final client = CatalogHttpClient(
        cdnBaseUrl: 'https://cdn.test',
        client: MockClient(
          (_) async => throw http.ClientException('Failed host lookup'),
        ),
      );
      expect(
        () => client.fetchPage(
          scope: 'wallpapers',
          slug: 'all',
          page: 1,
          itemFromJson: Wallpaper.fromJson,
        ),
        throwsA(isA<NetworkException>()),
      );
    });
  });

  group('CatalogVersion', () {
    test('caches for the session; invalidate() re-fetches', () async {
      var calls = 0;
      final mock = MockClient((_) async {
        calls++;
        return http.Response('{"content_version": "v$calls"}', 200);
      });
      final version = CatalogVersion(
        cdnBaseUrl: 'https://cdn.test',
        client: mock,
      );

      expect(await version.current(), 'v1');
      expect(await version.current(), 'v1', reason: 'session-cached');
      expect(calls, 1);

      version.invalidate();
      expect(await version.current(), 'v2');
      expect(calls, 2);
    });
  });
}
