import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import '../../../data/models/wallpaper.dart';

/// Aggressively prefetches upcoming LIVE wallpaper MP4s to a local disk cache so
/// that, by the time the feed reaches an item, its bytes are already on disk and
/// the player opens from a local file (instant first frame) instead of streaming
/// it from the CDN over a cold network path.
///
/// This is the **data window** half of the feed's two-window strategy, and it is
/// completely decoupled from the **decoder window** owned by
/// `VideoPreloadController`. Prefetching downloads bytes only — it spins up NO
/// ExoPlayer and NO video decoder — so we can read many items ahead without
/// touching the device's scarce concurrent-decoder budget. (Conflating the two
/// is exactly what made the old 3-player preload pool choke budget SoCs: it paid
/// a decoder per look-ahead slot.)
///
/// Trade-off (chosen deliberately): prefetching [_ahead] items on ANY connection
/// favours scroll smoothness over mobile-data thrift. Live previews are small
/// (≤15 MB, typically 2–5 MB) and [_maxCacheObjects] bounds total disk use.
class WallpaperPrefetchService {
  WallpaperPrefetchService({required this.cdnBaseUrl});

  /// CDN base used to build the public stream URL for live previews. Must match
  /// the URL the player opens, so a prefetched file is found in cache by key.
  final String cdnBaseUrl;

  /// How many items AHEAD of the current index to pull to disk. Deliberately
  /// large: prefetch is bytes-only (no player, no decoder — see class doc), so
  /// a deep window costs network + disk but NOT the scarce concurrent-decoder
  /// budget, which is the only thing that actually janks the feed. With
  /// nearest-first ordering ([prefetchAround]) and a capped concurrency, a deep
  /// window just keeps the pipe busy fetching the soon-to-be-seen clips ahead
  /// of the user; it never delays the nearest item. The cap on real perf cost
  /// is [_maxConcurrent], not this number.
  static const _ahead = 15;

  /// The ahead-window the FIRST pass of a process uses, until [_widened].
  ///
  /// On a cold sign-in nothing is cached, so the full [_ahead] window enqueued
  /// ~40 MB of look-ahead the instant the feed mounted — three of it downloading
  /// at once, against the one clip the user is actually staring at. That clip
  /// waits its turn for bandwidth and its first frame arrives late, which reads
  /// as "the app opened on a still image". Four ahead keeps the pipe busy for
  /// the next swipe or two without crowding the current card; the full depth
  /// arrives a moment later via [widenWindow], by which point the current card
  /// has already painted.
  static const _aheadCold = 4;

  /// Safety net for [widenWindow]: the widen signal is the current card's first
  /// painted frame, and a feed whose first item is STATIC never produces one.
  /// Rather than special-case that, the first pass simply widens on its own
  /// shortly after — the window is a bandwidth-priority hint, not a contract.
  static const _widenFallback = Duration(seconds: 3);

  /// A small BEHIND window so an immediate back-swipe also opens from cache.
  static const _behind = 1;

  /// Max simultaneous downloads — THE real performance/data guard (not the
  /// window depth). Bounded so the nearest item (the one most likely to be seen
  /// next) isn't starved behind several parallel transfers, and so a 4G link
  /// isn't saturated. Kept at 3 even as the window widened: more parallelism
  /// would split bandwidth and slow the nearest clip's first paint.
  static const _maxConcurrent = 3;

  /// LRU bound on object COUNT (flutter_cache_manager has no byte cap). Scaled
  /// with the wider window so the full look-ahead set survives eviction; ~120
  /// short clips, least-recently-used evicted first, so the items around the
  /// current index always survive.
  static const _maxCacheObjects = 120;

  /// Shared across controller re-creations (Android 12+ apply Activity recreate,
  /// re-login remount) so the on-disk cache and its LRU survive. flutter_cache_
  /// manager keys everything by the Config `key`, so even a fresh manager reads
  /// the same store — the singleton just avoids redundant manager instances.
  static final CacheManager _cache = CacheManager(
    Config(
      'arulLiveWallpapers',
      // Live previews rarely change once published; keep them a good while.
      stalePeriod: const Duration(days: 14),
      maxNrOfCacheObjects: _maxCacheObjects,
    ),
  );

  /// URLs currently queued or downloading. Claimed synchronously so concurrent
  /// [prefetchAround] calls (rapid page changes) never enqueue a duplicate.
  final Set<String> _tracked = {};

  /// Pending download URLs, nearest-to-current first. Rebuilt on every
  /// [prefetchAround] so a fling re-prioritises around where the user landed.
  final Queue<String> _queue = Queue<String>();

  int _active = 0;
  bool _disposed = false;

  /// False until the first card has painted (or [_widenFallback] elapsed), while
  /// which [prefetchAround] uses the narrow [_aheadCold] window. One-way: once
  /// the process is past its cold start there is nothing to stage again.
  bool _widened = false;
  Timer? _widenTimer;

  /// Last window [prefetchAround] was asked for, so the [_widenFallback] timer
  /// re-issues around where the user IS when it fires, not where they were when
  /// it was armed.
  List<Wallpaper> _lastItems = const [];
  int _lastIndex = 0;

  /// Whether the full [_ahead] depth is in effect. Read by the feed controller
  /// so it only arms its one-shot first-frame listener while staging is live.
  bool get windowWidened => _widened;

  /// Restores the full [_ahead] look-ahead and is a no-op afterwards. Called by
  /// `VideoPreloadController` when the current card renders its first frame —
  /// the moment the user has something to look at and the pipe is free again.
  /// Does NOT re-run [prefetchAround] itself: the caller owns the current index
  /// and re-issues the pass with it.
  void widenWindow() {
    if (_widened) return;
    _widened = true;
    _widenTimer?.cancel();
    _widenTimer = null;
    debugPrint(
      'FeedVideo: prefetch look-ahead widened to $_ahead '
      '(cold-start staging over)',
    );
  }

  /// The public CDN URL for a live item — the single source of truth for both
  /// the cache key and the player's network fallback.
  String urlFor(Wallpaper w) => '$cdnBaseUrl/${w.key}';

  /// Returns the absolute local path for [url] iff it is already in the disk
  /// cache, else null — never hits the network. The player uses this to choose
  /// between an instant local open and a progressive network stream.
  Future<String?> cachedPathOrNull(String url) async {
    if (_disposed) return null;
    try {
      final info = await _cache.getFileFromCache(url);
      return info?.file.path;
    } catch (_) {
      // Cache backend unavailable (e.g. path_provider not mocked in tests) —
      // treat as "not cached" so the player falls back to the network URL.
      return null;
    }
  }

  /// Downloads [url] if needed and completes once its bytes are on disk (or
  /// immediately if already cached), returning the local path — or null on
  /// failure. Unlike [prefetchAround] this AWAITS the transfer, so the splash
  /// gate can hold the branded splash until the very first live clip is local
  /// (the feed's player then opens from a file → instant first frame). It is
  /// safe to call alongside [prefetchAround]: flutter_cache_manager coalesces
  /// concurrent fetches of the same URL, so the warm prefetch already pulling
  /// this item and this await share one download.
  Future<String?> ensureCached(String url) async {
    if (_disposed) return null;
    try {
      final existing = await _cache.getFileFromCache(url);
      if (existing != null) return existing.file.path;
      final file = await _cache.getSingleFile(url);
      return file.path;
    } catch (_) {
      // Network/backend failure — caller falls back to streaming the CDN URL.
      return null;
    }
  }

  /// Enqueue downloads for the live items in the window around [currentIndex].
  /// Nearest-first, skipping anything already cached or already in flight. Safe
  /// (and intended) to call on every page settle.
  void prefetchAround(List<Wallpaper> items, int currentIndex) {
    if (_disposed || items.isEmpty) return;

    // Cold start: hold the window narrow until the current card has painted
    // (see [_aheadCold]), and arm the fallback that widens it regardless.
    if (!_widened) {
      _lastItems = items;
      _lastIndex = currentIndex;
      if (_widenTimer == null) {
        debugPrint(
          'FeedVideo: prefetch look-ahead staged at $_aheadCold for cold start',
        );
        _widenTimer = Timer(_widenFallback, () {
          if (_disposed || _widened) return;
          widenWindow();
          prefetchAround(_lastItems, _lastIndex);
        });
      }
    }
    final ahead = _widened ? _ahead : _aheadCold;

    // Drop stale QUEUED urls (in-flight downloads continue) and rebuild the
    // queue for the new window so priority always tracks the current index.
    for (final url in _queue) {
      _tracked.remove(url);
    }
    _queue.clear();

    final start = (currentIndex - _behind).clamp(0, items.length - 1);
    final end = (currentIndex + ahead).clamp(0, items.length - 1);

    final candidates = <int>[];
    for (var i = start; i <= end; i++) {
      if (items[i].kind == WallpaperKind.live) candidates.add(i);
    }
    // Nearest distance to current index first.
    candidates.sort(
      (a, b) => (a - currentIndex).abs().compareTo((b - currentIndex).abs()),
    );

    for (final i in candidates) {
      final url = urlFor(items[i]);
      if (_tracked.contains(url)) continue; // already queued or downloading
      _tracked.add(url); // synchronous claim → no duplicate enqueue
      _queue.add(url);
    }
    _pump();
  }

  void _pump() {
    while (!_disposed && _active < _maxConcurrent && _queue.isNotEmpty) {
      final url = _queue.removeFirst();
      _active++;
      unawaited(_download(url));
    }
  }

  Future<void> _download(String url) async {
    try {
      // getSingleFile no-ops if already cached & fresh; otherwise downloads.
      // Check cache first so a slot is freed instantly for genuinely-missing
      // items rather than spent re-reading a present file.
      final cached = await _cache.getFileFromCache(url);
      if (cached == null && !_disposed) {
        await _cache.getSingleFile(url);
      }
    } catch (_) {
      // Non-fatal: a failed prefetch just means the player streams the network
      // URL instead, and a later pass may retry.
    } finally {
      _active--;
      _tracked.remove(url);
      if (!_disposed) _pump();
    }
  }

  /// Stops scheduling new downloads. In-flight transfers are tiny and finish on
  /// their own; the disk cache persists for the next controller instance.
  void dispose() {
    _disposed = true;
    _widenTimer?.cancel();
    _widenTimer = null;
    _lastItems = const [];
    _queue.clear();
    _tracked.clear();
  }
}
