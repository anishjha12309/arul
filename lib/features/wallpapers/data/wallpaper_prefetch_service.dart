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
/// Prefetching on ANY connection favours scroll smoothness over mobile-data thrift, deliberately —
/// but the window depth is the DATA-PLAN budget: a clip averages ~4.5 MB, so every card the window
/// reaches costs that whether or not the user ever gets there. [_maxCacheObjects] bounds disk use.
class WallpaperPrefetchService {
  WallpaperPrefetchService({required this.cdnBaseUrl});

  /// CDN base for the public stream URL. MUST match the URL the player opens, or the key misses.
  final String cdnBaseUrl;

  /// How many items AHEAD of the current index to pull to disk. Deliberately SHALLOW.
  ///
  /// Prefetch is bytes-only -> the window costs network and disk, never the decoder budget, and
  /// nearest-first ordering plus [_maxConcurrent] keep the nearest item from waiting. But depth is
  /// what turns scrolling into data: at 15 the queue never drained while the user swiped, so the
  /// pipe ran flat out for the whole scroll — ~5 MB/s, 505 MB in 90 s of flinging on a 3 GB Vivo.
  /// Three covers the next swipe or two and then lets the pipe IDLE until the next page settles,
  /// so bytes track cards actually reached (~one clip per swipe), not time spent scrolling.
  static const _ahead = 3;

  /// The ahead-window the FIRST pass of a process uses, until [_widened].
  ///
  /// On a cold sign-in nothing is cached, and whatever is enqueued downloads against the one clip
  /// the user is staring at. If that clip waits for bandwidth it paints late — which reads as
  /// "the app opened on a still". Two ahead keeps the pipe busy for the next swipe without
  /// crowding the current card. The full depth arrives via [widenWindow], once it has painted.
  static const _aheadCold = 2;

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
  /// Deliberately far deeper than the window: this cache is what makes a cached cold start open
  /// every recent card from a local file, so a shallower window must not shrink it.
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

  /// How many `priority` [ensureCached] calls — bytes the user is STARING at — are outstanding.
  ///
  /// While any is, [_pump] starts no look-ahead transfer and every non-priority [ensureCached]
  /// waits, so the visible card owns the pipe. At ~4.5 MB a clip, the two window neighbours plus
  /// three look-ahead transfers sharing a thin pipe is what made the visible card wait on cards
  /// nobody had reached yet. It cannot deadlock: a priority call never waits on itself, and it
  /// fetches through the cache manager directly, joining any transfer of the SAME url already up.
  int _priorityWaiters = 0;

  Completer<void>? _priorityIdle;

  /// Downloads [url] if needed and completes once its bytes are on disk, returning the local path.
  ///
  /// Null on failure. Unlike [prefetchAround] this AWAITS the transfer.
  /// So the player can hold the poster until the clip is local, then open from a file.
  /// Safe alongside [prefetchAround] — flutter_cache_manager coalesces concurrent fetches of a URL.
  /// [priority] is the CURRENT card: it jumps every queue, and holds every other transfer.
  Future<String?> ensureCached(String url, {bool priority = false}) async {
    if (_disposed) return null;
    try {
      final existing = await _cache.getFileFromCache(url);
      if (existing != null) return existing.file.path;
      if (!priority) {
        // Yield to the visible card. Re-checked in a loop: another priority open may start while
        // this one waits, and a neighbour must never overtake it.
        while (!_disposed && _priorityIdle != null) {
          await _priorityIdle!.future;
        }
        if (_disposed) return null;
        // It may have landed while we waited — the priority transfer can be this very url.
        final landed = await _cache.getFileFromCache(url);
        if (landed != null) return landed.file.path;
      }
      if (priority) {
        _priorityWaiters++;
        _priorityIdle ??= Completer<void>();
      }
      try {
        final file = await _cache.getSingleFile(url);
        return file.path;
      } finally {
        if (priority && --_priorityWaiters == 0) {
          _priorityIdle?.complete();
          _priorityIdle = null;
        }
        if (!_disposed) _pump();
      }
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
    candidates.sort(
      (a, b) => (a - currentIndex).abs().compareTo((b - currentIndex).abs()),
    );

    for (final i in candidates) {
      final url = urlFor(items[i]);
      if (_tracked.contains(url)) continue;
      _tracked.add(url); // synchronous claim → no duplicate enqueue
      _queue.add(url);
    }
    _pump();
  }

  void _pump() {
    while (!_disposed &&
        _priorityWaiters == 0 &&
        _active < _maxConcurrent &&
        _queue.isNotEmpty) {
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
    // Release anything parked behind the visible card, or its future never completes.
    _priorityIdle?.complete();
    _priorityIdle = null;
    _widenTimer?.cancel();
    _widenTimer = null;
    _lastItems = const [];
    _queue.clear();
    _tracked.clear();
  }
}
