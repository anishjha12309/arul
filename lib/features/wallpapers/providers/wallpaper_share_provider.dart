import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/error/network_error.dart';
import '../../../data/models/wallpaper.dart';
import 'wallpaper_apply_provider.dart';
import 'wallpaper_prefetch_provider.dart';

sealed class WallpaperShareState {
  const WallpaperShareState();
}

final class WallpaperShareIdle extends WallpaperShareState {
  const WallpaperShareIdle();
}

final class WallpaperSharePreparing extends WallpaperShareState {
  const WallpaperSharePreparing({this.progress});

  /// 0.0–1.0 while the media downloads; null before the first byte lands.
  final double? progress;
}

final class WallpaperShareError extends WallpaperShareState {
  const WallpaperShareError({required this.message, this.isNetwork = false});

  /// DIAGNOSTIC ONLY -- never shown to a user (English, and can be a raw
  /// exception). The UI localizes from [isNetwork].
  final String message;
  final bool isNetwork;
}

class WallpaperShareNotifier extends Notifier<WallpaperShareState> {
  @override
  WallpaperShareState build() => const WallpaperShareIdle();

  /// Downloads the media (or reuses the cached copy the apply flow / prefetcher
  /// already put on disk) and hands it to the system share sheet.
  ///
  /// There is no "shared" success state: the share sheet is the OS's, and
  /// whether the user actually completed a share is not observable. We return to
  /// idle as soon as the sheet is handed off — claiming success would be a lie.
  Future<void> share(Wallpaper wallpaper, {required String message}) async {
    if (state is WallpaperSharePreparing) return; // re-entrancy guard

    final service = ref.read(wallpaperApplyServiceProvider);

    try {
      state = const WallpaperSharePreparing();

      // The SAME filename apply uses. Prefixing it `arul-` here meant apply-then-
      // share (or share-then-apply) of one wallpaper downloaded the identical bytes
      // twice, on a user's mobile data. The friendly name the recipient sees is a
      // share-sheet concern, handled by `fileNameOverrides` below — not by renaming
      // the cache entry.
      final filename = applyCacheFilename(wallpaper);
      final tmpDir = await getTemporaryDirectory();
      final cached = File('${tmpDir.path}/$filename');

      File? file;
      if (await cached.exists() && await cached.length() > 0) {
        file = cached;
      } else {
        // Reuse the feed prefetcher's copy when it has one — for a live wallpaper
        // being viewed, it almost always does.
        final prefetched = await ref
            .read(wallpaperPrefetchServiceProvider)
            .cachedPathOrNull(await service.resolveUrl(wallpaper));
        if (prefetched != null) {
          try {
            file = await File(prefetched).copy(cached.path);
          } catch (_) {
            // Evicted between lookup and copy — fall through to the download.
          }
        }
      }

      if (file == null) {
        final url = await service.resolveUrl(wallpaper);
        file = await service.downloadFile(url, filename, (p) {
          state = WallpaperSharePreparing(progress: p);
        });
      }

      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path)],
          // What the RECIPIENT sees. The cache file is named for its content, so
          // this is where the brand goes — without forking the cache.
          fileNameOverrides: ['arul-${wallpaper.id}${_ext(wallpaper)}'],
          text: message,
        ),
      );
      state = const WallpaperShareIdle();
    } catch (e) {
      final network = isNetworkError(e);
      state = WallpaperShareError(message: e.toString(), isNetwork: network);
    }
  }

  void reset() => state = const WallpaperShareIdle();
}

final wallpaperShareProvider =
    NotifierProvider<WallpaperShareNotifier, WallpaperShareState>(
      WallpaperShareNotifier.new,
    );

/// The shared file's extension, so the recipient's gallery/player recognises it.
String _ext(Wallpaper w) {
  final name = w.key.split('/').last;
  final dot = name.lastIndexOf('.');
  return dot == -1 ? '' : name.substring(dot);
}
