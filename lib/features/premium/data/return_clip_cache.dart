import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// The return page's clip, pulled to disk while the person is inside the UPI app.
/// Its own cache, not the feed's: that one is an LRU of 120 wallpapers that would evict this clip
/// within a scroll, and this one holds a language cut or two, forever warm for the next abandon.
abstract final class ReturnClipCache {
  static final CacheManager _cache = CacheManager(
    Config(
      'arulReturnClip',
      stalePeriod: const Duration(days: 30),
      // One cut per language the phone has been in, plus a re-cut's `?v=` key while the old one ages.
      maxNrOfCacheObjects: 4,
    ),
  );

  static Future<String?> pathIfCached(String url) async {
    try {
      final info = await _cache.getFileFromCache(url);
      return info?.file.path;
    } catch (e) {
      debugPrint('[ReturnClip] cache read failed: $e');
      return null;
    }
  }

  /// Starts pulling [url] to disk and returns at once. Coalesced by the cache manager, so a second
  /// handoff inside one download is free; a failure is silent and the page streams the URL instead.
  static void warm(String url) {
    unawaited(
      _cache
          .getSingleFile(url)
          .then<void>(
            (_) {},
            onError: (Object e) => debugPrint('[ReturnClip] warm failed: $e'),
          ),
    );
  }
}
