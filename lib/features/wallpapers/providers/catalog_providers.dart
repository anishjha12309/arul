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
/// 200 items/page), drained to a single list because the feed filters by
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
  /// Bounded fan-out for the page drain. At 200 rows/page the whole drain is
  /// page 1 + one parallel batch today, but the pool must stay: the catalog
  /// grows in bulk imports, and a strictly sequential drain serialises every
  /// RTT on a throttled CDN path — the cold start (no disk snapshot yet) sat
  /// at ~5 s when 634 items were 32 pages of 20. Mirrors the reference's
  /// bounded-concurrency discipline (WallpaperPrefetchService pumps at most a
  /// few transfers at once so nothing is starved); one shared http.Client
  /// keeps the TCP/TLS sessions pooled.
  static const _maxConcurrentPages = 4;

  /// Monotonic token: each build()/refresh() claims a new one, and a background
  /// revalidate only writes state if it is still the latest — so a stale drain
  /// can never overwrite a newer refresh with older data.
  int _fetchSeq = 0;

  /// Delays between automatic re-checks while the feed is parked on a network
  /// error with nothing to show, after Riverpod's own exponential-backoff
  /// retries (~13 s of quick [build] re-runs) are exhausted.
  ///
  /// Those quick retries exist for a cold-start radio/DNS blip. They do nothing
  /// for the real-world case: a user opens the app in a lift, a metro or a dead
  /// zone, gets the error card, and then signal returns — the app has no
  /// connectivity listener anywhere, so it never noticed and the card stayed
  /// until a manual Retry. Mirrors
  /// [RingtoneCatalogNotifier.offlineRecheckBackoffs]; both feeds shared the
  /// defect, so both carry the fix.
  ///
  /// The ladder lengthens to two minutes and then holds, so a genuinely offline
  /// device settles into one cheap catalog fetch every two minutes rather than
  /// spinning the radio. Empty disables it (tests).
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
    // The provider outlives the screen, so the timer has to die with it or it
    // keeps waking the radio after the tab is gone. Registered per build, so a
    // rebuild (manual Retry invalidates this provider) also clears any pending
    // re-check before the new load claims its own.
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
    try {
      final fresh = await _fetchCatalog();
      _recheckAttempt = 0;
      unawaited(_writeCache(file, fresh));
      return fresh;
    } catch (e) {
      // Only a NETWORK failure is worth re-checking on a timer — it is the one
      // that fixes itself when the link comes back. A parse miss or a missing
      // catalog will fail identically forever and must wait for a manual retry.
      // The ladder resets on every build() failure (Riverpod's quick retries
      // land here too), so the first slow re-check after they give up is 5 s,
      // not two minutes.
      if (isNetworkError(e)) {
        _recheckAttempt = 0;
        _scheduleOfflineRecheck(seq);
      }
      rethrow;
    }
  }

  /// Queue the next automatic re-check after a network failure left the feed
  /// with nothing to show. The timer drives [refresh], which re-reads the
  /// version pointer — a catalog published during the outage is picked up.
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

  /// Background refresh behind a served cache. Failure is silent — the user is
  /// already looking at a working feed of the last good catalog.
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

  /// Pull-to-refresh AND the offline re-check timer's retry: authoritative
  /// network reload. Re-reads the version pointer (so a just-published catalog
  /// is picked up), bypasses the serve-cached-first fast path, and only settles
  /// when fresh data (or a failure) lands. On failure with data on screen the
  /// current feed is kept — the indicator simply settles; the error state is
  /// reserved for a feed that has nothing to show, and only THAT state keeps
  /// the re-check ladder climbing.
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
/// seventh deity server-side needs no app release. Ordered by
/// [compareBrowseCategories]: Sivan first, then alphabetical.
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
    ..sort(compareBrowseCategories);
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
/// Every chip runs the SAME comparator ([orderedByUse]); a category chip is just
/// All restricted to one category. That is the invariant: a filtered view can
/// never contradict All. It holds because the comparator is a total order and
/// its last tier is catalog POSITION — position within the filtered list is
/// monotonic in position within the full one, so restricting the set cannot
/// reverse any pair.
///
/// [apply_restore] resolves its saved page index through this too. That index is
/// a position in the list the feed SERVES, so it must be validated against the
/// same ordering or a post-apply restart restores to a different wallpaper.
List<Wallpaper> feedOrder(String slug, List<Wallpaper> all) => orderedByUse(
  slug == WallpaperCategory.allSlug
      ? all
      : all.where((w) => w.category == slug).toList(growable: false),
  (w) => w.applyCount,
  rank: (w) => w.feedRank,
);

/// The three-tier feed order (CLAUDE.md §5b), for any catalog list carrying a
/// pin and a use counter:
///
///   1. [rank] ascending, **nulls last** — the admin's pins.
///   2. [useCount] descending — popularity.
///   3. catalog position ascending — newest-first within a category,
///      interleaved across them by the Worker.
///
/// Shared with the Ringtones tab, whose model and provider are separate but
/// whose rule is identical — written once so the two lists cannot drift apart.
///
/// Tier 1 is sparse by design: a null rank is the ordinary state, so most of the
/// catalog falls straight through to tier 2. This is what lets an import land
/// safely — new rows arrive unranked and cannot displace the curated head.
///
/// Tier 3 is load-bearing and must not be dropped for a bare sort on the earlier
/// keys: Dart's `List.sort` is NOT stable, so ties — most of the catalog, most
/// of the time, since an uncurated row with no applies ties on both tiers above —
/// would come out in an order free to change between runs. The feed compares
/// served lists by ORDERED IDS (`_syncFeed`), so that would re-point the pager
/// and the video pool under a scrolling user on every cold start, revalidate and
/// pull-refresh. Decorating with the index keeps the order TOTAL and a pure
/// function of the list it is given.
///
/// The zero state is exactly right and is not a fallback: with nothing pinned
/// and nothing applied, every comparison falls through to the index and the feed
/// is plain catalog order — newest-first, interleaved.
List<T> orderedByUse<T>(
  List<T> all,
  int Function(T) useCount, {
  required int? Function(T) rank,
}) {
  // Decorate-sort-undecorate: read each key ONCE per row rather than twice per
  // comparison — this runs on the chip tap that returns to All.
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
/// Nulls last is the whole contract — an unpinned row must sink BELOW every pin
/// and be decided by popularity instead. Treating null as a number would do the
/// opposite of the feature: as 0 it would pin the entire uncurated catalog above
/// the curated head, and as a large value it would still make the pins a total
/// order over rows the admin never touched.
int _compareRank(int? a, int? b) {
  if (a == null) return b == null ? 0 : 1;
  if (b == null) return -1;
  return a.compareTo(b);
}

/// The feed: catalog filtered by the selected CATEGORY, in [feedOrder]. Never
/// filtered by kind — static and live interleave by design (CLAUDE.md §5b).
final feedProvider = Provider<AsyncValue<List<Wallpaper>>>((ref) {
  final slug = ref.watch(selectedCategoryProvider);
  return ref.watch(catalogProvider).whenData((all) => feedOrder(slug, all));
});

/// Native first-frame stills — the grid's fallback for a live wallpaper whose
/// pre-generated thumbnail is missing. App-scoped so its in-flight memo is shared
/// across grid rebuilds and a fling issues one native call per clip, not one per
/// build.
final videoThumbnailServiceProvider = Provider<VideoThumbnailService>(
  (ref) => VideoThumbnailService(),
);
