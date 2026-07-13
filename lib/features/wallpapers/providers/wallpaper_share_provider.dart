import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/error/network_error.dart';
import '../../../data/models/wallpaper.dart';
import 'wallpaper_apply_provider.dart';

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

      final filename = 'arul-${wallpaper.key.split('/').last}';
      final tmpDir = await getTemporaryDirectory();
      final cached = File('${tmpDir.path}/$filename');

      File file;
      if (await cached.exists() && await cached.length() > 0) {
        file = cached;
      } else {
        final url = await service.resolveUrl(wallpaper);
        file = await service.downloadFile(url, filename, (p) {
          state = WallpaperSharePreparing(progress: p);
        });
      }

      await SharePlus.instance.share(
        ShareParams(files: [XFile(file.path)], text: message),
      );
      state = const WallpaperShareIdle();
    } catch (e) {
      final network = isNetworkError(e);
      state = WallpaperShareError(
        message: network ? 'offline' : e.toString(),
        isNetwork: network,
      );
    }
  }

  void reset() => state = const WallpaperShareIdle();
}

final wallpaperShareProvider =
    NotifierProvider<WallpaperShareNotifier, WallpaperShareState>(
      WallpaperShareNotifier.new,
    );
