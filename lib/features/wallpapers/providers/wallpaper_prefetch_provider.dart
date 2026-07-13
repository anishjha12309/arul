import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config.dart';
import '../data/wallpaper_prefetch_service.dart';

/// App-scoped singleton for the live-wallpaper byte prefetcher.
///
/// Owned here rather than by [VideoPreloadController] so the WARM prefetch can
/// start the moment the catalog lands at app root — during splash, before the
/// feed ever mounts — instead of only once the feed widget builds. The
/// controller reads this same instance, so its per-page prefetch and the root
/// warm prefetch share one in-flight queue and never double-download an item.
///
/// keepAlive matters: the on-disk cache is a static singleton inside the
/// service, but the in-flight tracking is instance state. One shared instance
/// keeps that coordination intact across screen mount/dispose and across the
/// Android 12+ apply Activity recreate.
final wallpaperPrefetchServiceProvider = Provider<WallpaperPrefetchService>((
  ref,
) {
  final service = WallpaperPrefetchService(cdnBaseUrl: AppConfig.cdnBaseUrl);
  ref.onDispose(service.dispose);
  return service;
});
