import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../../data/models/catalog_page.dart';
import '../../../data/models/wallpaper.dart';
import '../../../data/repositories/repository_providers.dart';
import '../data/video_thumbnail_service.dart';

/// Where the last good catalog is kept (a `{"items":[…]}` snapshot of the
/// drained Worker catalog, in the same snake_case item shape).
const _catalogCacheFile = 'catalog.json';

/// Directory holding the catalog snapshot. A provider seam so tests can point
/// it at a temp dir (path_provider has no platform channel under
/// `flutter test`); production always resolves the app-support dir.
final catalogCacheDirProvider = FutureProvider<Directory>(
  (_) => getApplicationSupportDirectory(),
);

/// The catalog: the Worker-built, edge-cached page set
/// (`catalog/version.json` no-store → `catalog/wallpapers/all_{page}.json?v=`,
/// 20 items/page), drained to a single list because the feed filters by
/// category client-side.
///
/// **Cache-FIRST (stale-while-revalidate), deliberately.** On a warm start the
/// last good catalog is served from disk immediately — the wallpapers
/// themselves are already in the image/video caches, so the feed paints in one
/// frame — while the network drain runs in the background and swaps the fresh
/// list in when it lands. This is what keeps a relaunch instant even on a
/// slow-but-alive connection: the old network-first path sat on the loading
/// state for the whole version.json + multi-page drain before showing anything.
///
/// A cold start (no cache yet) keeps the plain network path: fetch, parse,
/// cache, or surface the error. Only a failure with NO cached catalog at all is
/// a real error. Pull-to-refresh calls [CatalogNotifier.refresh], which
/// bypasses the cached fast path so an explicit refresh always means fresh data.
final catalogProvider = AsyncNotifierProvider<CatalogNotifier, List<Wallpaper>>(
  CatalogNotifier.new,
);

class CatalogNotifier extends AsyncNotifier<List<Wallpaper>> {
  /// Bounded fan-out for the page drain. The pages are tiny edge-cached JSON,
  /// but the drain is up to ~22 requests — strictly sequential it serialises
  /// every RTT on a throttled CDN path. Mirrors the reference's bounded-
  /// concurrency discipline (WallpaperPrefetchService pumps at most a few
  /// transfers at once so nothing is starved); one shared http.Client keeps
  /// the TCP/TLS sessions pooled.
  static const _maxConcurrentPages = 4;

  /// Monotonic token: each build()/refresh() claims a new one, and a background
  /// revalidate only writes state if it is still the latest — so a stale drain
  /// can never overwrite a newer refresh with older data.
  int _fetchSeq = 0;

  @override
  Future<List<Wallpaper>> build() async {
    final file = await _cacheFile();
    final seq = ++_fetchSeq;

    if (await file.exists()) {
      try {
        final cached = _parseCache(await file.readAsString());
        if (cached.isNotEmpty) {
          // Serve the disk snapshot NOW; revalidate from the network in the
          // background and swap the fresh catalog in when it arrives.
          unawaited(_revalidate(file, seq));
          return cached;
        }
      } catch (_) {
        // Corrupt cache (a kill mid-write on an older build). Drop it and take
        // the cold network path — never let a bad snapshot brick cold starts.
        await file.delete().catchError((_) => file);
      }
    }

    // Cold start / self-healed cache: network is the only source. A failure
    // here IS the error state (the feed renders retry).
    final fresh = await _fetchCatalog();
    unawaited(_writeCache(file, fresh));
    return fresh;
  }

  /// Background refresh behind a served cache. Failure is silent — the user is
  /// already looking at a working feed of the last good catalog.
  Future<void> _revalidate(File file, int seq) async {
    try {
      final fresh = await _fetchCatalog();
      await _writeCache(file, fresh);
      if (ref.mounted && seq == _fetchSeq) {
        state = AsyncData(fresh);
      }
    } catch (e) {
      debugPrint('[catalog] background revalidate failed (serving cache): $e');
    }
  }

  /// Pull-to-refresh: authoritative network reload. Re-reads the version
  /// pointer (so a just-published catalog is picked up), bypasses the
  /// serve-cached-first fast path, and only settles when fresh data (or a
  /// failure) lands. On failure with data on screen the current feed is kept —
  /// the indicator simply settles; the error state is reserved for a feed that
  /// has nothing to show.
  Future<void> refresh() async {
    invalidateCatalogVersion();
    final seq = ++_fetchSeq;
    try {
      final fresh = await _fetchCatalog();
      unawaited(_writeCache(await _cacheFile(), fresh));
      if (ref.mounted && seq == _fetchSeq) state = AsyncData(fresh);
    } catch (e, st) {
      if (!ref.mounted || seq != _fetchSeq) return;
      if (!state.hasValue) state = AsyncError(e, st);
    }
  }

  /// Drains the full catalog: page 1 (which carries `total_pages`), then the
  /// remaining pages with at most [_maxConcurrentPages] in flight, reassembled
  /// in page order. A missing page N means end-of-pages (or a transient miss)
  /// — everything up to it is served, matching the sequential drain's `break`.
  Future<List<Wallpaper>> _fetchCatalog() async {
    final client = ref.read(catalogHttpClientProvider);

    Future<CatalogPage<Wallpaper>?> fetch(int page) => client.fetchPage(
      scope: 'wallpapers',
      slug: 'all',
      page: page,
      itemFromJson: Wallpaper.fromJson,
    );

    final first = await fetch(1);
    if (first == null) {
      // Page 1 missing on the CDN means the catalog has never been built —
      // an operational fault, not an app state.
      throw StateError('catalog page 1 missing on CDN');
    }

    final all = [...first.items];
    final totalPages = first.totalPages;
    if (first.hasMore && totalPages > 1) {
      // Worker pool over pages 2..totalPages; results land slotted by page so
      // ordering is deterministic regardless of completion order.
      final slots = List<CatalogPage<Wallpaper>?>.filled(totalPages - 1, null);
      var next = 2;
      Future<void> worker() async {
        while (true) {
          final page = next++;
          if (page > totalPages) return;
          slots[page - 2] = await fetch(page);
        }
      }

      final workers = (totalPages - 1).clamp(1, _maxConcurrentPages);
      await Future.wait([for (var i = 0; i < workers; i++) worker()]);

      for (final page in slots) {
        // End-of-pages / transient miss — serve what we have up to it.
        if (page == null) break;
        all.addAll(page.items);
      }
    }

    return List<Wallpaper>.unmodifiable(all);
  }

  Future<File> _cacheFile() async {
    final dir = await ref.read(catalogCacheDirProvider.future);
    return File('${dir.path}/$_catalogCacheFile');
  }
}

/// Write AFTER a successful parse, so a malformed response can never poison the
/// cache and brick every future cold start. Best-effort.
Future<void> _writeCache(File file, List<Wallpaper> items) async {
  try {
    await file.writeAsString(
      jsonEncode({
        'items': [for (final w in items) w.toJson()],
      }),
    );
  } catch (e) {
    debugPrint('[catalog] cache write failed (non-fatal): $e');
  }
}

List<Wallpaper> _parseCache(String json) {
  final body = jsonDecode(json) as Map<String, dynamic>;
  final items = (body['items'] as List).cast<Map<String, dynamic>>();
  return items.map(Wallpaper.fromJson).toList(growable: false);
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
