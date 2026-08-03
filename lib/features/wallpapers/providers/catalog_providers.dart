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

/// The list the feed serves for [slug] — the ONE definition of feed order.
///
/// A category chip keeps catalog order, which is newest-first: build-catalog
/// emits `sort_order ASC, created_at DESC, id ASC` and filtering preserves
/// relative order.
///
/// All is a curated block followed by a stable shuffle of everything else.
///
/// The shuffled tail is the older half of the contract, and catalog order is
/// what it exists to fix: an import is a single transaction, so a 30-wallpaper
/// Sivan batch shares `sort_order` AND `created_at` and those 30 tie on every
/// key but `id` — they land as 30 CONSECUTIVE slots at the head of the default
/// feed, and one import owns the whole first screenful.
///
/// The curated block in front of it is [Wallpaper.feedRank], set by hand in the
/// CMS: All is the landing view, and a hash gives filler the same odds of the
/// first screen as a hero wallpaper. Only ranked rows join it. An uncurated
/// import therefore lands in the TAIL, deliberately — putting new rows on top
/// instead would re-create the consecutive-block defect above.
///
/// [apply_restore] resolves its saved page index through this too. That index is
/// a position in the list the feed SERVES, so it must be validated against the
/// same ordering or a post-apply restart restores to a different wallpaper.
List<Wallpaper> feedOrder(String slug, List<Wallpaper> all) =>
    slug == WallpaperCategory.allSlug
    ? _orderedForAll(all)
    : all.where((w) => w.category == slug).toList(growable: false);

/// Curated head (`feedRank` ascending) + [_shuffledForAll] of the remainder.
///
/// Ranks are sparse and hand-assigned, so a tie is possible (two saves racing,
/// a hand-edited row); `id` breaks it to keep the order TOTAL, exactly as the
/// shuffle does. With no ranks set — the shipped state — this is byte-identical
/// to the plain shuffle.
List<Wallpaper> _orderedForAll(List<Wallpaper> all) {
  final curated = <Wallpaper>[];
  final rest = <Wallpaper>[];
  for (final w in all) {
    (w.feedRank == null ? rest : curated).add(w);
  }
  if (curated.isEmpty) return _shuffledForAll(rest);
  curated.sort((a, b) {
    final byRank = a.feedRank!.compareTo(b.feedRank!);
    return byRank != 0 ? byRank : a.id.compareTo(b.id);
  });
  return List<Wallpaper>.unmodifiable([...curated, ..._shuffledForAll(rest)]);
}

/// Order [all] by a hash of each row's id.
///
/// The hash is the point: this is recomputed on every catalog emission — cold
/// start, background revalidate, pull-refresh, the hourly cron's rebuild — and
/// the feed compares served lists by ORDERED IDS (`_syncFeed`). A per-call
/// random order would therefore look like new content on every one of those and
/// re-point the pager and the video pool under a scrolling user. Hashing the id
/// makes the order a pure function of the catalog's contents: the All feed reads
/// the same on every launch, and publishing a wallpaper inserts it at its own
/// position instead of shifting everything below it.
List<Wallpaper> _shuffledForAll(List<Wallpaper> all) {
  // Decorate-sort-undecorate: hash each id ONCE (n hashes) instead of twice per
  // comparison (~2n·log n) — this runs on the chip tap that returns to All.
  final keyed = [for (final w in all) (_fnv1a(w.id), w)];
  keyed.sort((a, b) {
    final byHash = a.$1.compareTo(b.$1);
    // Two ids can collide in 32 bits. Falling back to the id keeps the order
    // TOTAL, so it never depends on the order the rows arrived in.
    return byHash != 0 ? byHash : a.$2.id.compareTo(b.$2.id);
  });
  return List<Wallpaper>.unmodifiable([for (final e in keyed) e.$2]);
}

/// FNV-1a, 32-bit, over the string's UTF-16 code units (low byte then high, so
/// a non-ASCII id can't silently collide with its ASCII truncation).
///
/// Hand-rolled deliberately: `String.hashCode` is not contractually stable
/// across Dart releases, and this order has to survive app upgrades. Relies on
/// 64-bit ints to hold the intermediate product exactly — true on the Dart VM,
/// which is the only target Arul ships (Android-only in v1).
int _fnv1a(String s) {
  var hash = 0x811c9dc5;
  for (var i = 0; i < s.length; i++) {
    final unit = s.codeUnitAt(i);
    hash = ((hash ^ (unit & 0xff)) * 0x01000193) & 0xffffffff;
    hash = ((hash ^ (unit >> 8)) * 0x01000193) & 0xffffffff;
  }
  return hash;
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
