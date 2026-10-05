import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import '../../../app/widgets/reel/reel_prefetch_service.dart';
import '../../../data/models/wallpaper.dart';

/// Prefetches upcoming LIVE wallpaper MP4s to a local disk cache, ahead of the feed reaching them.
/// The player then opens from a local FILE — instant first frame — never a cold CDN stream.
class WallpaperPrefetchService extends ReelPrefetchService<Wallpaper> {
  WallpaperPrefetchService({required super.cdnBaseUrl})
    : super(cache: () => _cache, ahead: _ahead, aheadCold: _aheadCold);

  /// How many items AHEAD of the current index to pull to disk. Deliberately SHALLOW.
  static const _ahead = 3;

  /// Two ahead keeps the pipe busy for the next swipe without crowding the current card.
  static const _aheadCold = 2;

  /// LRU bound on object COUNT — flutter_cache_manager has no byte cap.
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
}
