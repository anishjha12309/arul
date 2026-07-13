import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config.dart';
import '../presentation/video_preload_controller.dart';
import 'wallpaper_prefetch_provider.dart';

/// App-scoped (keepAlive) [VideoPreloadController].
///
/// WHY app-scoped and not viewer-owned: an apply can recreate the Activity
/// (Android 12+ re-extracts Material You colours on a wallpaper change), and a
/// viewer-owned controller would be tearing itself down while that happens — a
/// `dispose()` in flight against a recreating Activity. Living for the process
/// removes that race entirely.
///
/// NOTE: `prewarmFirst` on the controller is currently DEAD CODE. It exists for a
/// splash gate that warms the first clip before reveal; this app does not have one
/// (the splash is a fixed beat straight to the grid). Wire it or delete it — do
/// not assume it runs.
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
