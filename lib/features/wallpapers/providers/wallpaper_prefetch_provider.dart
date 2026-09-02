import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config.dart';
import '../data/wallpaper_prefetch_service.dart';

/// App-scoped singleton for the live-wallpaper byte prefetcher.
///
/// Owned HERE, not by [VideoPreloadController] -> the warm prefetch starts when the catalog lands.
/// That is during splash, before the feed ever mounts.
/// The controller reads this same instance -> one in-flight queue, never a double download.
/// keepAlive matters: the disk cache is static, but the in-flight tracking is INSTANCE state.
/// One shared instance keeps that intact across a remount and across the apply Activity recreate.
final wallpaperPrefetchServiceProvider = Provider<WallpaperPrefetchService>((
  ref,
) {
  final service = WallpaperPrefetchService(cdnBaseUrl: AppConfig.cdnBaseUrl);
  ref.onDispose(service.dispose);
  return service;
});
