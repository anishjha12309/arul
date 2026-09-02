import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/error/app_exception.dart';
import '../../../data/models/catalog_page.dart';
import '../../../data/models/wallpaper.dart';
import '../../../data/repositories/repository_providers.dart';
import '../data/video_thumbnail_service.dart';

/// Where the last good catalog is kept — a `{"items":[…]}` snapshot in the same snake_case shape.
const _catalogCacheFile = 'catalog.json';

/// Directory holding the catalog snapshot — a provider SEAM, so tests can point at a temp dir.
/// path_provider has no platform channel under `flutter test`; production resolves app-support.
final catalogCacheDirProvider = FutureProvider<Directory>(
  (_) => getApplicationSupportDirectory(),
);

/// The catalog — the Worker-built, edge-cached page set, drained to ONE list.
/// The feed filters by category client-side, so pages are never fetched per chip.
///
/// **Cache-FIRST, stale-while-revalidate, deliberately.**
/// A warm start serves the disk snapshot at once, and the media is already in the caches.
/// So the feed paints in one frame while the network drain swaps the fresh list in behind it.
/// The old network-first path sat on the loading state for version.json plus the whole drain.
/// A cold start with no cache keeps the plain network path: fetch, parse, cache, or error.
/// ONLY a failure with no cached catalog at all is a real error.
/// [CatalogNotifier.refresh] bypasses the cached fast path -> an explicit refresh means fresh data.
final catalogProvider = AsyncNotifierProvider<CatalogNotifier, List<Wallpaper>>(
  CatalogNotifier.new,
);

class CatalogNotifier extends AsyncNotifier<List<Wallpaper>> {
  /// Bounded fan-out for the page drain — at 200 rows a page this is page 1 plus one batch today.
  /// The pool must STAY: the catalog grows in bulk imports.
  /// A sequential drain serialises every RTT on a throttled CDN path — 32 pages once cost ~5 s cold.
  /// One shared http.Client keeps the TCP/TLS sessions pooled.
  static const _maxConcurrentPages = 4;

  /// Monotonic token — each build/refresh claims one, and a revalidate writes only while it is latest.
  /// So a stale drain can never overwrite a newer refresh with older data.
  int _fetchSeq = 0;

  /// Delays between automatic re-checks while the feed is parked on a network error, showing nothing.
  ///
  /// Riverpod's own ~13 s of quick retries cover a cold-start radio or DNS blip, and nothing else.
  /// A user in a lift gets the error card, signal returns, and no connectivity listener notices.
  /// The card then stayed until a manual Retry -> this ladder is the fix, mirrored in both feeds.
  /// It lengthens to two minutes and HOLDS -> an offline device settles, never spins the radio.
  /// Empty disables it (tests).
  @visibleForTesting
  static List<Duration> offlineRecheckBackoffs = const [
    Duration(seconds: 5),
    Duration(seconds: 15),
    Duration(seconds: 30),
    Duration(seconds: 60),
    Duration(seconds: 120),
  ];

  Timer? _recheckTimer;
  int _recheckAttempt = 0;

  @override
  Future<List<Wallpaper>> build() async {
    // The provider outlives the screen -> the timer must die with it, or it wakes the radio after.
    // Registered per build, so a rebuild also clears any pending re-check before the new load.
    ref.onDispose(() {
      _recheckTimer?.cancel();
      _recheckTimer = null;
    });

    final file = await _cacheFile();
    final seq = ++_fetchSeq;

    if (await file.exists()) {
      try {
        final cached = _parseCache(await file.readAsString());
        if (cached.isNotEmpty) {
          // Serve the disk snapshot NOW -> revalidate in the background and swap the fresh list in.
          unawaited(_revalidate(file, seq));
          return cached;
        }
      } catch (_) {
        // A corrupt cache — a kill mid-write — must NEVER brick cold starts.
        // Drop it and take the cold network path.
        await file.delete().catchError((_) => file);
      }
    }

    // Cold start, or a self-healed cache -> the network is the only source.
    // A failure here IS the error state, and the feed renders retry.
    try {
      final fresh = await _fetchCatalog();
      _recheckAttempt = 0;
      unawaited(_writeCache(file, fresh));
      return fresh;
    } catch (e) {
      // Only a NETWORK failure is worth a timer — it is the one that fixes itself.
      // A parse miss or a missing catalog fails identically forever and needs a manual retry.
      // The ladder resets on every build() failure -> the first slow re-check is 5 s, not two minutes.
      if (isNetworkError(e)) {
        _recheckAttempt = 0;
        _scheduleOfflineRecheck(seq);
      }
      rethrow;
    }
  }

  /// Queue the next automatic re-check after a network failure left the feed with nothing to show.
  /// The timer drives [refresh], which re-reads the version pointer -> an outage-time publish lands.
  void _scheduleOfflineRecheck(int seq) {
    _recheckTimer?.cancel();
    final ladder = offlineRecheckBackoffs;
    if (ladder.isEmpty) return;
    final delay = ladder[_recheckAttempt.clamp(0, ladder.length - 1)];
    _recheckAttempt++;
    _recheckTimer = Timer(delay, () {
      // A newer load (manual retry, pull-refresh, rebuild) supersedes us.
      if (seq != _fetchSeq) return;
      unawaited(refresh());
    });
  }

  /// Background refresh behind a served cache — failure is SILENT.
  /// The user is already looking at a working feed of the last good catalog.
  Future<void> _revalidate(File file, int seq) async {
    try {
      final fresh = await _fetchCatalog();
      _recheckAttempt = 0;
      await _writeCache(file, fresh);
      if (ref.mounted && seq == _fetchSeq) {
        state = AsyncData(fresh);
      }
    } catch (e) {
      debugPrint('[catalog] background revalidate failed (serving cache): $e');
    }
  }

  /// Pull-to-refresh AND the offline timer's retry — an authoritative network reload.
  ///
  /// Re-reads the version pointer, bypasses the cached fast path, settles only on fresh data.
  /// On failure WITH data on screen the current feed is kept and the indicator simply settles.
  /// The error state is reserved for a feed with nothing to show, and only that climbs the ladder.
  Future<void> refresh() async {
    invalidateCatalogVersion();
    final seq = ++_fetchSeq;
    try {
      final fresh = await _fetchCatalog();
      // The link is up — the next outage starts the ladder from the top.
      _recheckAttempt = 0;
      _recheckTimer?.cancel();
      unawaited(_writeCache(await _cacheFile(), fresh));
      if (ref.mounted && seq == _fetchSeq) state = AsyncData(fresh);
    } catch (e, st) {
      if (!ref.mounted || seq != _fetchSeq) return;
      if (!state.hasValue) {
        state = AsyncError(e, st);
        if (isNetworkError(e)) _scheduleOfflineRecheck(seq);
      }
    }
  }

  /// Drains the full catalog — page 1 carries `total_pages`, then the rest, bounded and reassembled.
  /// A missing page N means end-of-pages, or a transient miss -> everything up to it is served.
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
      // Page 1 missing on the CDN means the catalog was never built — an operational fault.
      throw StateError('catalog page 1 missing on CDN');
    }

    final all = [...first.items];
    final totalPages = first.totalPages;
    if (first.hasMore && totalPages > 1) {
      // Worker pool over pages 2..totalPages, slotted BY PAGE -> order is completion-independent.
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
        // End-of-pages, or a transient miss -> serve what we have up to it.
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

/// Write AFTER a successful parse -> a malformed response can never poison the cache. Best-effort.
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

/// Categories DERIVED from the catalog -> a seventh deity server-side needs no app release.
///
/// ORDER comes from the CMS when an operator has set one (`app_config.category_order`),
/// else [compareBrowseCategories]: Sivan first, then alphabetical. The two are layered,
/// never mixed -> [orderedByCms] puts every listed slug first in the operator's order and
/// leaves everything else to the built-in rule, so a category published after the last
/// drag still appears in its usual slot.
///
/// The config is a separate CDN fetch from the catalog, so it can land LATER. Watching it
/// here means the row simply re-sorts when it does; until then the built-in rule holds,
/// which is also exactly what an install predating the field does forever.
final categoriesProvider = Provider<List<WallpaperCategory>>((ref) {
  final all = switch (ref.watch(catalogProvider)) {
    AsyncData(:final value) => value,
    _ => const <Wallpaper>[],
  };
  final cfg = switch (ref.watch(appConfigProvider)) {
    AsyncData(:final value) => value,
    _ => null,
  };
  final labels = <String, String>{};
  for (final w in all) {
    labels.putIfAbsent(w.category, () => w.categoryLabel);
  }
  return orderedByCms(
    labels.entries.map((e) => WallpaperCategory(e.key, e.value)).toList(),
    categoryOrderFor(cfg?.categoryOrder, 'wallpapers'),
    compareBrowseCategories,
  );
});

final selectedCategoryProvider = NotifierProvider<SelectedCategory, String>(
  SelectedCategory.new,
);

class SelectedCategory extends Notifier<String> {
  @override
  String build() => WallpaperCategory.allSlug;

  void select(String slug) => state = slug;
}

/// The list the feed serves for [slug] — the ONE definition of feed order.
///
/// EVERY chip runs the same comparator; a category chip is All restricted to one category.
/// The invariant: a filtered view can never contradict All.
/// It holds because the comparator is a TOTAL order whose last tier is catalog position.
/// Position in the filtered list is monotonic in the full one -> restricting cannot reverse a pair.
/// [apply_restore] resolves its saved page index through this too — a position in the SERVED list.
/// Validating it against any other ordering restores a post-apply restart to a different wallpaper.
List<Wallpaper> feedOrder(String slug, List<Wallpaper> all) => orderedByUse(
  slug == WallpaperCategory.allSlug
      ? all
      : all.where((w) => w.category == slug).toList(growable: false),
  (w) => w.applyCount,
  rank: (w) => w.feedRank,
);

/// The three-tier feed order (CLAUDE.md §5b), for any catalog list with a rank and a use counter:
///
///   1. [rank] ascending, **nulls last**;
///   2. [useCount] descending — popularity;
///   3. catalog position ascending — the order the Worker built.
///
/// Shared with the Ringtones tab, written once so the two lists cannot drift apart.
/// Tier 1 is SPARSE by design — a null rank is ordinary, so most of the catalog reaches tier 2.
/// That is what lets an import land safely: new rows arrive unranked and displace nothing.
/// Tier 3 is load-bearing. Dart's `List.sort` is NOT stable, and most rows tie on both tiers above.
/// Their order would then be free to change between runs.
/// The feed compares served lists by ORDERED IDS -> that re-points the pager under a scrolling user.
/// Decorating with the index keeps the order TOTAL and a pure function of the list it is given.
/// The zero state is exactly right, not a fallback: everything falls through to plain catalog order.
List<T> orderedByUse<T>(
  List<T> all,
  int Function(T) useCount, {
  required int? Function(T) rank,
}) {
  // Decorate-sort-undecorate — read each key ONCE per row, not twice per comparison.
  // This runs on the chip tap that returns to All.
  final keyed = [
    for (var i = 0; i < all.length; i++)
      (rank: rank(all[i]), count: useCount(all[i]), i: i, row: all[i]),
  ];
  keyed.sort((a, b) {
    final byRank = _compareRank(a.rank, b.rank);
    if (byRank != 0) return byRank;
    final byCount = b.count.compareTo(a.count); // descending — most used first
    return byCount != 0 ? byCount : a.i.compareTo(b.i); // then catalog order
  });
  return List<T>.unmodifiable([for (final e in keyed) e.row]);
}

/// `feed_rank` ASC, NULLS LAST.
///
/// Nulls last is the whole contract — an unranked row sinks BELOW every ranked one.
/// Popularity then decides it. Treating null as a NUMBER inverts the feature.
/// As 0 it would put the entire unranked catalog on top; as a large value it still orders untouched rows.
int _compareRank(int? a, int? b) {
  if (a == null) return b == null ? 0 : 1;
  if (b == null) return -1;
  return a.compareTo(b);
}

/// The feed — catalog filtered by the selected CATEGORY, in [feedOrder].
/// NEVER filtered by kind: static and live interleave by design (CLAUDE.md §5b).
final feedProvider = Provider<AsyncValue<List<Wallpaper>>>((ref) {
  final slug = ref.watch(selectedCategoryProvider);
  return ref.watch(catalogProvider).whenData((all) => feedOrder(slug, all));
});

/// Native first-frame stills — the fallback for a live wallpaper whose thumbnail is missing.
/// App-scoped -> the in-flight memo is shared, and a fling issues one native call per CLIP.
final videoThumbnailServiceProvider = Provider<VideoThumbnailService>(
  (ref) => VideoThumbnailService(),
);
