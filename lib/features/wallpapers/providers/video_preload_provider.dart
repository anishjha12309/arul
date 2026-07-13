import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config.dart';
import '../presentation/video_preload_controller.dart';
import 'wallpaper_prefetch_provider.dart';

/// App-scoped (keepAlive) [VideoPreloadController].
///
/// WHY app-scoped and not screen-owned: the splash gate warms the FIRST live
/// wallpaper's decoder and paints its first frame BEFORE the feed mounts, so the
/// first live page reveals already playing instead of shimmering. A screen-owned
/// controller cannot exist before that reveal. Living for the process also
/// removes the apply / Android-12-Activity-recreate teardown race that a
/// screen-owned controller has to fight (no `dispose()` in flight while the
/// Activity is being recreated).
///
/// Decoder budget: the controller holds at most previous/current/next (3
/// decoders), so a back-swipe lands on a pre-decoded frame exactly like a
/// forward swipe. It demotes itself to 2 and then 1 if the device reports
/// decoder errors or a software fallback. Decoders are released on app
/// background and — awaited — immediately before a native apply, so the OS
/// wallpaper chooser finds the hardware codecs free.
final videoPreloadControllerProvider = Provider<VideoPreloadController>((ref) {
  final controller = VideoPreloadController(
    cdnBaseUrl: AppConfig.cdnBaseUrl,
    prefetch: ref.read(wallpaperPrefetchServiceProvider),
  );
  ref.onDispose(controller.dispose);
  return controller;
});
