import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config.dart';
import '../presentation/video_preload_controller.dart';
import 'wallpaper_prefetch_provider.dart';

/// App-scoped (keepAlive) [VideoPreloadController].
///
/// An apply can recreate the Activity — Android 12+ re-extracts Material You colours.
/// A viewer-owned controller would be disposing itself against a recreating Activity.
/// Living for the PROCESS removes that race entirely.
/// NOTE: `prewarmFirst` on the controller is DEAD CODE — nothing calls it.
/// The splash warms through the thumbnail path instead, images rather than MP4 decoders.
/// Wire `prewarmFirst` or delete it — do not assume it runs.
/// The controller holds at most previous/current/next -> a back-swipe lands pre-decoded.
/// It demotes itself to 2 and then 1 on decoder errors or a software fallback.
/// Decoders are released on background, and AWAITED before a native apply.
/// So the OS wallpaper chooser finds the hardware codecs free.
final videoPreloadControllerProvider = Provider<VideoPreloadController>((ref) {
  final controller = VideoPreloadController(
    cdnBaseUrl: AppConfig.cdnBaseUrl,
    prefetch: ref.read(wallpaperPrefetchServiceProvider),
  );
  ref.onDispose(controller.dispose);
  return controller;
});
