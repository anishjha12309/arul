import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import '../../../app/widgets/reel/reel_prefetch_service.dart';
import '../domain/status_video.dart';

/// Stages upcoming status clips on disk. Its own store, so clips never evict live wallpapers.
class StatusPrefetchService extends ReelPrefetchService<StatusVideo> {
  StatusPrefetchService({required super.cdnBaseUrl})
    : super(cache: () => _cache, ahead: 2, aheadCold: 1);

  /// ~8 MB a clip -> 20 caps the store near 160 MB on phones that are mostly low-end.
  static final CacheManager _cache = CacheManager(
    Config(
      'arulStatuses',
      stalePeriod: const Duration(days: 14),
      maxNrOfCacheObjects: 20,
    ),
  );
}
