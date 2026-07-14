import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/analytics/analytics_provider.dart';
import '../../../core/config/app_config.dart';
import '../../../core/crash/crash_provider.dart';
import '../../../core/error/app_exception.dart';
import '../../../data/models/wallpaper.dart';
import '../../../data/repositories/repository_providers.dart';
import '../../referral/data/install_referrer_service.dart';
import '../data/wallpaper_apply_service.dart';
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

  /// Downloads the media through the signed-URL gate (or reuses the cached copy
  /// the apply flow / prefetcher already put on disk) and hands it to the
  /// system share sheet with [message] + a referral-attributed Play link as the
  /// caption.
  ///
  /// There is no "shared" success state: the share sheet is the OS's, and
  /// whether the user actually completed a share is not observable. We return to
  /// idle as soon as the sheet is handed off — claiming success would be a lie.
  Future<void> share(Wallpaper wallpaper, {required String message}) async {
    if (state is WallpaperSharePreparing) return; // re-entrancy guard

    final service = ref.read(wallpaperApplyServiceProvider);
    final analytics = ref.read(analyticsServiceProvider);
    final crash = ref.read(crashReporterProvider);

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
        // being viewed, it almost always does. Looked up by the PUBLIC url (the
        // prefetcher's cache key), never the one-shot signed url.
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
        // The GATED download URL (Worker signed-url when the backend exists).
        final url = await service.downloadUrl(wallpaper);
        file = await service.downloadFile(url, filename, (p) {
          state = WallpaperSharePreparing(progress: p);
        });
      }

      final link = await _installLink();

      // Idle BEFORE the sheet: share() resolves only when the sheet closes, so
      // leaving Preparing set would strand the progress bar beneath it.
      state = const WallpaperShareIdle();

      final result = await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path)],
          // What the RECIPIENT sees (`arul-<title-slug>.<ext>`) instead of the
          // R2 object key's opaque name. The cache file is named for its
          // content, so this is where the brand goes — without forking the cache.
          fileNameOverrides: [_recipientFilename(wallpaper, filename)],
          text: '$message\n$link',
        ),
      );

      analytics.track(
        'wallpaper_shared',
        properties: {
          'wallpaper_id': wallpaper.id,
          'type': wallpaper.kind.name,
          'category': wallpaper.category,
          'result': result.status.name,
        },
      );
    } on WallpaperApplyException catch (e, st) {
      // Share failures gate a core premium action — record like apply does.
      crash.recordError(e, st, reason: 'wallpaper share failed');
      state = WallpaperShareError(message: e.message);
    } catch (e, st) {
      final network = isNetworkError(e);
      if (!network) {
        crash.recordError(e, st, reason: 'wallpaper share unexpected error');
      }
      state = WallpaperShareError(message: e.toString(), isNetwork: network);
    }
  }

  /// The Play Store link for the share caption: referral-attributed when the
  /// user's code loads in time, otherwise the plain listing. Never blocks the
  /// share on the referral call — the file is the payload, the link is a bonus.
  Future<String> _installLink() async {
    if (AppConfig.hasBackend) {
      try {
        final summary = await ref
            .read(referralRepositoryProvider)
            .getReferralSummary()
            .timeout(const Duration(seconds: 2));
        final code = summary.referralCode;
        if (code != null && code.isNotEmpty) {
          return InstallReferrerService.buildShareLink(code);
        }
      } catch (_) {
        // Offline mid-flow / slow server / no code — fall through.
      }
    }
    return 'https://play.google.com/store/apps/details?id=$kPlayPackageId';
  }

  /// Friendly filename shown to the recipient (`arul-<title-slug>.<ext>`).
  String _recipientFilename(Wallpaper wallpaper, String storedFilename) {
    final dot = storedFilename.lastIndexOf('.');
    final ext = dot == -1 ? '' : storedFilename.substring(dot);
    var slug = wallpaper.title
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    if (slug.isEmpty) slug = 'wallpaper';
    if (slug.length > 40) slug = slug.substring(0, 40);
    return 'arul-$slug$ext';
  }

  void reset() => state = const WallpaperShareIdle();
}

final wallpaperShareProvider =
    NotifierProvider<WallpaperShareNotifier, WallpaperShareState>(
      WallpaperShareNotifier.new,
    );
