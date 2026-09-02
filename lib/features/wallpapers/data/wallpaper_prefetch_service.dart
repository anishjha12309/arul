import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import '../../../data/models/wallpaper.dart';

/// Prefetches upcoming LIVE wallpaper MP4s to a local disk cache, ahead of the feed reaching them.
/// The player then opens from a local FILE — instant first frame — never a cold CDN stream.
///
/// The **data window** half of the feed's two-window strategy, decoupled from the DECODER window.
/// Prefetching downloads bytes only — NO ExoPlayer, NO decoder -> many items ahead cost no decoders.
/// Conflating the two is what made a 3-player preload pool choke budget SoCs: a decoder per slot.
/// Prefetching on ANY connection favours scroll smoothness over mobile-data thrift, deliberately.
/// Live previews are small (≤15 MB, typically 2–5 MB) and [_maxCacheObjects] bounds total disk use.
class WallpaperPrefetchService {
  WallpaperPrefetchService({required this.cdnBaseUrl});

  /// CDN base for the public stream URL. MUST match the URL the player opens, or the key misses.
  final String cdnBaseUrl;

  /// How many items AHEAD of the current index to pull to disk. Deliberately large.
  ///
  /// Prefetch is bytes-only -> a deep window costs network and disk, never the decoder budget.
  /// The decoder budget is the only thing that actually janks the feed.
  /// Nearest-first ordering plus capped concurrency -> a deep window never delays the nearest item.
  /// The cap on real perf cost is [_maxConcurrent], not this number.
  static const _ahead = 15;

  /// The ahead-window the FIRST pass of a process uses, until [_widened].
  ///
  /// On a cold sign-in nothing is cached -> the full window enqueued ~40 MB the instant it mounted.
  /// Three of those downloaded at once, against the one clip the user is staring at.
  /// That clip waits for bandwidth and paints late — which reads as "the app opened on a still".
  /// Four ahead keeps the pipe busy for the next swipe or two without crowding the current card.
  /// The full depth arrives via [widenWindow], by which point the current card has painted.
  static const _aheadCold = 4;

  /// Safety net for [widenWindow] — the widen signal is a first painted FRAME.
  /// A feed whose first item is STATIC never produces one -> the first pass widens on its own.
  /// The window is a bandwidth-priority hint, not a contract.
  static const _widenFallback = Duration(seconds: 3);

  /// A small BEHIND window so an immediate back-swipe also opens from cache.
  static const _behind = 1;

  /// Max simultaneous downloads — THE real performance and data guard, not the window depth.
  ///
  /// Bounded so the nearest item is never starved behind parallel transfers, and 4G is not saturated.
  /// Kept at 3 even as the window widened -> more parallelism splits bandwidth and slows first paint.
  static const _maxConcurrent = 3;

  /// LRU bound on object COUNT — flutter_cache_manager has no byte cap.
  /// Scaled with the window so the full look-ahead set survives; the current index's items always do.
  static const _maxCacheObjects = 120;

  /// Shared across controller re-creations -> the on-disk cache and its LRU survive an apply recreate.
  /// flutter_cache_manager keys by the Config `key`, so even a fresh manager reads the same store.
  /// The singleton just avoids redundant manager instances.
  static final CacheManager _cache = CacheManager(
    Config(
      'arulLiveWallpapers',
      // Live previews rarely change once published -> keep them a good while.
      stalePeriod: const Duration(days: 14),
      maxNrOfCacheObjects: _maxCacheObjects,
    ),
  );

  /// URLs currently queued or downloading.
  /// Claimed SYNCHRONOUSLY -> concurrent [prefetchAround] calls never enqueue a duplicate.
  final Set<String> _tracked = {};

  /// Pending download URLs, nearest-to-current first.
  /// Rebuilt on every [prefetchAround] -> a fling re-prioritises around where the user landed.
  final Queue<String> _queue = Queue<String>();

  int _active = 0;
  bool _disposed = false;

  /// False until the first card paints or [_widenFallback] elapses -> [prefetchAround] stays narrow.
  /// ONE-WAY: past a cold start there is nothing left to stage.
  bool _widened = false;
  Timer? _widenTimer;

  /// The last window [prefetchAround] was asked for.
  /// So the [_widenFallback] timer re-issues around where the user IS, not where they were.
  List<Wallpaper> _lastItems = const [];
  int _lastIndex = 0;

  /// Whether the full [_ahead] depth is in effect.
  /// Read by the feed controller -> it arms its one-shot first-frame listener only while staging.
  bool get windowWidened => _widened;

  /// Restores the full [_ahead] look-ahead; a no-op afterwards.
  ///
  /// Called when the current card renders its first frame — the user has something to look at.
  /// Does NOT re-run [prefetchAround] — the caller owns the current index and re-issues with it.
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

  /// The public CDN URL for a live item — one source of truth for the cache key AND the fallback.
  String urlFor(Wallpaper w) => '$cdnBaseUrl/${w.key}';

  /// The absolute local path for [url] only if it is already cached, else null — NEVER the network.
  /// The player uses it to choose between an instant local open and a progressive stream.
  Future<String?> cachedPathOrNull(String url) async {
    if (_disposed) return null;
    try {
      final info = await _cache.getFileFromCache(url);
      return info?.file.path;
    } catch (_) {
      // Cache backend unavailable -> treat as "not cached" and let the player use the network URL.
      return null;
    }
  }

  /// Downloads [url] if needed and completes once its bytes are on disk, returning the local path.
  ///
  /// Null on failure. Unlike [prefetchAround] this AWAITS the transfer.
  /// So a caller can hold a screen until the first live clip is local, then open from a file.
  /// Safe alongside [prefetchAround] — flutter_cache_manager coalesces concurrent fetches of a URL.
  Future<String?> ensureCached(String url) async {
    if (_disposed) return null;
    try {
      final existing = await _cache.getFileFromCache(url);
      if (existing != null) return existing.file.path;
      final file = await _cache.getSingleFile(url);
      return file.path;
    } catch (_) {
      // Network or backend failure -> the caller falls back to streaming the CDN URL.
      return null;
    }
  }

  /// Enqueue downloads for the live items around [currentIndex], nearest-first.
  /// Skips anything already cached or in flight — safe, and intended, on every page settle.
  void prefetchAround(List<Wallpaper> items, int currentIndex) {
    if (_disposed || items.isEmpty) return;

    // Cold start: hold the window narrow until the current card paints, and arm the widen fallback.
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

    // Drop stale QUEUED urls, in-flight ones continue, and rebuild for the new window.
    // So priority always tracks the current index.
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
    // Nearest distance to the current index first.
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
      // getSingleFile no-ops when already cached and fresh, otherwise downloads.
      // Check the cache FIRST -> a slot frees instantly rather than re-reading a present file.
      final cached = await _cache.getFileFromCache(url);
      if (cached == null && !_disposed) {
        await _cache.getSingleFile(url);
      }
    } catch (_) {
      // Non-fatal — a failed prefetch just means the player streams instead, and a pass may retry.
    } finally {
      _active--;
      _tracked.remove(url);
      if (!_disposed) _pump();
    }
  }

  /// Stops scheduling new downloads.
  /// In-flight transfers are tiny and finish on their own; the disk cache persists.
  void dispose() {
    _disposed = true;
    _widenTimer?.cancel();
    _widenTimer = null;
    _lastItems = const [];
    _queue.clear();
    _tracked.clear();
  }
}
