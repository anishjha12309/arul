import 'dart:async';

import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/config/build_info.dart';
import '../../../core/connectivity/data_saver.dart';
import '../../../core/experiments/experiments.dart';
import '../../../core/perf/boot_trace.dart';
import '../../../data/models/wallpaper.dart';
import '../../wallpapers/providers/catalog_providers.dart';
import '../../wallpapers/providers/wallpaper_prefetch_provider.dart';
import '../domain/auth_service.dart';
import '../domain/regional_art.dart';
import 'auth_providers.dart';

part 'launch_clip_provider.g.dart';

/// The regional poster's own live clip as a local file, once it may play over the poster; null
/// keeps the poster, which is also every failure's answer (launch-surface.md).
///
/// Read from the splash before its sign-in attempt, so Google's surface coming up is never missed.
@Riverpod(keepAlive: true)
class LaunchClip extends _$LaunchClip {
  final _surfaced = Completer<void>();
  bool _asked = false;

  @override
  String? build() {
    if (!ref.read(experimentsProvider).regionalActive) return null;
    // The sign-in path stays under 1 MB until Google's surface is up, or the attempt has ended.
    final signals = SignInPhase.signals.stream.listen((_) {
      if (!_surfaced.isCompleted) _surfaced.complete();
    });
    ref.onDispose(() => unawaited(signals.cancel()));
    return null;
  }

  /// The wall painted [poster]. Only the first call counts: the art never changes in a process.
  void wallUp(RegionalPoster poster) {
    if (_asked || !ref.read(experimentsProvider).regionalActive) return;
    _asked = true;
    unawaited(_fetch(poster));
  }

  Future<void> _fetch(RegionalPoster poster) async {
    try {
      // The lotus's own poster rule: no auth player on these phones, so no clip bytes either.
      final prefetch = ref.read(wallpaperPrefetchServiceProvider);
      if (prefetch.cdnBaseUrl.isEmpty || await DeviceMemory.isLow) return;
      await _surfaced.future;
      final items = await ref
          .read(catalogProvider.future)
          .timeout(const Duration(seconds: 30));
      final clip = items
          .where(
            (w) => w.id == poster.wallpaperId && w.kind == WallpaperKind.live,
          )
          .firstOrNull;
      if (clip == null || !ref.mounted) return;
      if (await DataSaver.refresh()) return;
      if (ref.read(authServiceProvider).currentState.isAuthenticated) return;
      BootTrace.mark('launch clip: download start');
      final path = await prefetch.ensureCached(prefetch.urlFor(clip));
      BootTrace.mark('launch clip: ${path == null ? 'failed' : 'on disk'}');
      if (path != null && ref.mounted) state = path;
    } catch (_) {
      // A slow catalog, a failed transfer: the poster simply stays.
    }
  }
}
