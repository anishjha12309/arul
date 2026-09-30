import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/analytics/journey_stamps.dart';
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
    final active = ref.read(experimentsProvider).regionalActive;
    JourneyStamps.noteClipArm(active: active);
    if (!active) return null;
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
      // The poster rule: no auth player on these phones, so no clip bytes either.
      final prefetch = ref.read(wallpaperPrefetchServiceProvider);
      if (await DeviceMemory.isLow) {
        JourneyStamps.noteWallClip('poster');
        return;
      }
      if (prefetch.cdnBaseUrl.isEmpty) {
        JourneyStamps.noteWallClip('no_cdn');
        return;
      }
      await _surfaced.future;
      final key = poster.launchClipKey;
      final String? url;
      if (key != null) {
        url = '${prefetch.cdnBaseUrl}/$key';
      } else {
        final items = await ref
            .read(catalogProvider.future)
            .timeout(const Duration(seconds: 30));
        final clip = items
            .where(
              (w) => w.id == poster.wallpaperId && w.kind == WallpaperKind.live,
            )
            .firstOrNull;
        url = clip == null ? null : prefetch.urlFor(clip);
      }
      if (!ref.mounted) return;
      if (url == null) {
        JourneyStamps.noteWallClip('no_clip');
        return;
      }
      if (await DataSaver.refresh()) {
        JourneyStamps.noteWallClip('data_saver');
        return;
      }
      if (ref.read(authServiceProvider).currentState.isAuthenticated) return;
      if (_slowLink(
        warmUpMs: ref.read(apiClientProvider).firstWarmUpMs,
        network: JourneyStamps.networkFacts,
      )) {
        JourneyStamps.noteWallClip('slow_link');
        return;
      }
      BootTrace.mark('launch clip: download start');
      JourneyStamps.noteWallClip('downloading');
      final path = await prefetch.ensureCached(url);
      BootTrace.mark('launch clip: ${path == null ? 'failed' : 'on disk'}');
      JourneyStamps.noteWallClip(path == null ? 'failed' : 'on_disk');
      if (path != null && ref.mounted) state = path;
    } catch (_) {
      // A slow catalog, a failed transfer: the poster simply stays.
      JourneyStamps.noteWallClip('error');
    }
  }
}

/// A multi-MB clip on a slow link lands while Google mints the token and our login POST is in
/// flight, so the poster stays. Either reading alone decides: the splash's API warm-up (a TLS
/// handshake that crawls is a crawling link) or a cellular modem estimate below 3G-class.
bool _slowLink({required int? warmUpMs, required Map<String, Object> network}) {
  if (warmUpMs != null && warmUpMs > 1500) return true;
  final kbps = network['net_kbps'];
  final metered = network['net_metered'] == true;
  return metered && kbps is int && kbps > 0 && kbps < 2000;
}

@visibleForTesting
bool slowLinkForClip({
  required int? warmUpMs,
  required Map<String, Object> network,
}) => _slowLink(warmUpMs: warmUpMs, network: network);
