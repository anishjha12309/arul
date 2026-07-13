import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../../../core/config/app_config.dart';
import '../../../data/models/wallpaper.dart';
import '../data/video_thumbnail_service.dart';

/// How long to wait for the server to RESPOND before declaring the network dead.
///
/// Measured, not guessed: fully offline, an un-timed `http.get` took **~50
/// seconds** to surface a DNS failure — fifty seconds of skeleton tiles before the
/// user was told anything.
///
/// Critically this bounds the RESPONSE, not the download. Bounding the whole
/// transfer looks equivalent and is not: the catalog for 428 items is a few
/// hundred KB, which on the 2G/EDGE connections a chunk of this audience actually
/// has takes well over eight seconds to pull. That user would time out, retry from
/// byte zero, and time out again — the app would simply never load for them, while
/// working fine on every developer's wifi. Headers arriving proves the network is
/// alive; after that we let the bytes take as long as they take.
const _catalogResponseTimeout = Duration(seconds: 8);

/// Where the last good catalog is kept.
const _catalogCacheFile = 'catalog.json';

/// PREVIEW SOURCE (UI phase): the bucket's own content-prep manifest.
///
/// Port-map Phase 4 repoints this at the Worker-built catalog
/// (`catalog/wallpapers/all_{page}.json` + `version.json` for `?v=` busting) and
/// adds paging. Nothing above this provider changes — the widgets already
/// consume `Wallpaper`.
///
/// **Cache-fallback, deliberately.** The network is fetched first, so a fresh
/// catalog always wins. But if it fails, the last good catalog is served from
/// disk instead of an error screen: the wallpapers themselves are already in the
/// image cache, so a user on a dead train connection still gets a working grid
/// of everything they have seen, rather than a retry button. Only a failure with
/// NO cached catalog at all is a real error.
final catalogProvider = FutureProvider<List<Wallpaper>>((ref) async {
  final file = await _cacheFile();

  try {
    final client = http.Client();
    try {
      // The timeout is on the RESPONSE, not the body — see the constant's docs.
      final streamed = await client
          .send(
            http.Request(
              'GET',
              Uri.parse('${AppConfig.cdnBaseUrl}/catalog/catalog.json'),
            ),
          )
          .timeout(_catalogResponseTimeout);

      if (streamed.statusCode != 200) {
        throw Exception('catalog ${streamed.statusCode}');
      }
      final bytes = await streamed.stream.toBytes();
      final wallpapers = _parse(utf8.decode(bytes));

      // Write AFTER parsing, so a malformed response can never poison the cache
      // and brick every future cold start.
      unawaited(file.writeAsBytes(bytes).catchError((_) => file));
      return wallpapers;
    } finally {
      client.close();
    }
  } catch (e) {
    if (await file.exists()) {
      try {
        return _parse(await file.readAsString());
      } catch (_) {
        // Corrupt cache (a kill mid-write on an older build). Drop it and report
        // the original network failure rather than a confusing parse error.
        await file.delete().catchError((_) => file);
      }
    }
    rethrow;
  }
});

List<Wallpaper> _parse(String json) {
  final body = jsonDecode(json) as Map<String, dynamic>;
  final assets = (body['assets'] as List).cast<Map<String, dynamic>>();
  return assets.map(Wallpaper.fromManifest).toList(growable: false);
}

Future<File> _cacheFile() async {
  final dir = await getApplicationSupportDirectory();
  return File('${dir.path}/$_catalogCacheFile');
}

/// Categories, derived from the catalog — not a hardcoded list, so adding a
/// seventh deity server-side needs no app release.
final categoriesProvider = Provider<List<WallpaperCategory>>((ref) {
  final all = switch (ref.watch(catalogProvider)) {
    AsyncData(:final value) => value,
    _ => const <Wallpaper>[],
  };
  final labels = <String, String>{};
  for (final w in all) {
    labels.putIfAbsent(w.category, () => w.categoryLabel);
  }
  return labels.entries
      .map((e) => WallpaperCategory(e.key, e.value))
      .toList(growable: false)
    ..sort((a, b) => a.label.compareTo(b.label));
});

final selectedCategoryProvider = NotifierProvider<SelectedCategory, String>(
  SelectedCategory.new,
);

class SelectedCategory extends Notifier<String> {
  @override
  String build() => WallpaperCategory.allSlug;

  void select(String slug) => state = slug;
}

/// The feed: catalog filtered by the selected CATEGORY. Never by kind — static
/// and live interleave by design (CLAUDE.md §5b).
final feedProvider = Provider<AsyncValue<List<Wallpaper>>>((ref) {
  final slug = ref.watch(selectedCategoryProvider);
  return ref
      .watch(catalogProvider)
      .whenData(
        (all) => slug == WallpaperCategory.allSlug
            ? all
            : all.where((w) => w.category == slug).toList(growable: false),
      );
});

/// Native first-frame stills — the grid's fallback for a live wallpaper whose
/// pre-generated thumbnail is missing. App-scoped so its in-flight memo is shared
/// across grid rebuilds and a fling issues one native call per clip, not one per
/// build.
final videoThumbnailServiceProvider = Provider<VideoThumbnailService>(
  (ref) => VideoThumbnailService(),
);
