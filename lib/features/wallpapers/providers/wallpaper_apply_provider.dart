import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/error/network_error.dart';
import '../../../core/providers/shared_preferences_provider.dart';
import '../../../data/models/wallpaper.dart';
import '../data/wallpaper_apply_service.dart';

// ─── Pending-apply flags ──────────────────────────────────────────────────────
//
// Written to SharedPreferences BEFORE the native apply call. On Android 12+ a
// wallpaper change makes the OS re-extract Material You colours and can recreate
// our Activity (flutter#133722); the live-wallpaper chooser also opens over us.
// These flags let the feed jump straight back to the page the user was on,
// instead of showing a full-screen spinner — a flicker instead of a visible cold
// restart. Set for BOTH static and live.

const appliedWallpaperPendingKey = 'applied_wallpaper_pending';
const pendingApplyPageIndexKey = 'pending_apply_page_index';
const pendingApplyCategoryKey = 'pending_apply_category';

/// True when the pending apply was LIVE. Position is restored for both, but only
/// static shows an "applied" confirmation: we cannot observe the live chooser's
/// outcome, so claiming success there would be a lie.
const pendingApplyIsLiveKey = 'pending_apply_is_live';

// ─── State ────────────────────────────────────────────────────────────────────

enum WallpaperApplyStage { preparing, downloading, applying }

sealed class WallpaperApplyState {
  const WallpaperApplyState();
}

final class WallpaperApplyIdle extends WallpaperApplyState {
  const WallpaperApplyIdle();
}

final class WallpaperApplyLoading extends WallpaperApplyState {
  const WallpaperApplyLoading({required this.stage, this.progress});

  final WallpaperApplyStage stage;

  /// 0.0–1.0 while downloading; null for the other stages (which are indefinite,
  /// so the UI must show an indeterminate indicator, not a 0% bar).
  final double? progress;
}

final class WallpaperApplySuccess extends WallpaperApplyState {
  const WallpaperApplySuccess({required this.isLive});
  final bool isLive;
}

final class WallpaperApplyError extends WallpaperApplyState {
  const WallpaperApplyError({required this.message, this.isNetwork = false});

  final String message;

  /// Offline, not broken. The UI shows a retry affordance and a friendly line
  /// rather than an exception string.
  final bool isNetwork;
}

// ─── Service provider ─────────────────────────────────────────────────────────

final wallpaperApplyServiceProvider = Provider<WallpaperApplyService>(
  (ref) => CdnWallpaperApplyService(),
);

// ─── Notifier ─────────────────────────────────────────────────────────────────

class WallpaperApplyNotifier extends Notifier<WallpaperApplyState> {
  @override
  WallpaperApplyState build() => const WallpaperApplyIdle();

  /// Runs the whole apply flow. [releaseVideoDecoders] is awaited immediately
  /// before the native call so the feed's ExoPlayers give up the hardware codecs
  /// the wallpaper engine (or the OS chooser) is about to need — on a budget SoC
  /// there are only a handful, and not doing this is what makes an applied live
  /// wallpaper fall back to software decode and stutter.
  Future<void> apply(
    Wallpaper wallpaper, {
    required ApplyTarget target,
    int? feedPageIndex,
    String? category,
    Future<void> Function()? releaseVideoDecoders,
  }) async {
    // Re-entrancy guard: a double-tap on Apply must not start two downloads and
    // two native calls racing to write the same temp file.
    if (state is WallpaperApplyLoading) return;

    final service = ref.read(wallpaperApplyServiceProvider);
    final prefs = ref.read(sharedPreferencesProvider);
    final isLive = wallpaper.kind == WallpaperKind.live;

    try {
      final filename = wallpaper.key.split('/').last;
      final tmpDir = await getTemporaryDirectory();
      final cachedFile = File('${tmpDir.path}/$filename');
      final isCached =
          await cachedFile.exists() && await cachedFile.length() > 0;

      File file;
      if (isCached) {
        // Already on disk — e.g. the user dismissed the OEM chooser last time,
        // or the prefetcher already pulled this clip. Skip the network entirely.
        state = const WallpaperApplyLoading(
          stage: WallpaperApplyStage.applying,
        );
        file = cachedFile;
      } else {
        state = const WallpaperApplyLoading(
          stage: WallpaperApplyStage.preparing,
        );
        final url = await service.resolveUrl(wallpaper);

        state = const WallpaperApplyLoading(
          stage: WallpaperApplyStage.downloading,
          progress: 0,
        );
        file = await service.downloadFile(url, filename, (p) {
          state = WallpaperApplyLoading(
            stage: WallpaperApplyStage.downloading,
            progress: p,
          );
        });
      }

      state = const WallpaperApplyLoading(stage: WallpaperApplyStage.applying);

      // Persist restore state BEFORE the native call — see the flag docs above.
      if (feedPageIndex != null) {
        await prefs.setInt(pendingApplyPageIndexKey, feedPageIndex);
      }
      if (category != null) {
        await prefs.setString(pendingApplyCategoryKey, category);
      }
      await prefs.setBool(pendingApplyIsLiveKey, isLive);
      await prefs.setBool(appliedWallpaperPendingKey, true);

      if (isLive) {
        // Two live paths, decided natively:
        //  • our service is ALREADY the active wallpaper → the running engine's
        //    video is swapped in place. No chooser, and the outcome IS
        //    observable, so we report real success.
        //  • otherwise the OS live-wallpaper chooser opens as its own activity
        //    and the user makes the final "Set wallpaper" tap. We cannot observe
        //    that, so we finish IDLE — never a false "applied" confirmation.
        final swappedInPlace = await service.isOwnLiveWallpaperActive();

        // Chooser path only: hand our decoders to the chooser's preview engine
        // before it launches. On the in-place path the native side reuses the
        // already-running engine, and releasing would just black-frame the feed.
        if (!swappedInPlace && releaseVideoDecoders != null) {
          await releaseVideoDecoders();
        }
        await service.applyLiveWallpaper(file, target);

        if (swappedInPlace) {
          await _clearPending(prefs);
          state = const WallpaperApplySuccess(isLive: true);
        } else {
          // Flags stay set: if the chooser causes a recreate, the feed restores
          // position; if it doesn't, the feed consumes them on next resume.
          state = const WallpaperApplyIdle();
        }
        return;
      }

      // Static. Awaited decoder release first — the apply can recreate the
      // Activity, and a completed disposal cannot race Flutter teardown.
      if (releaseVideoDecoders != null) await releaseVideoDecoders();
      await service.applyStaticWallpaper(file, target);

      // We got here, so no OS restart happened: clear flags, confirm inline.
      await _clearPending(prefs);
      state = const WallpaperApplySuccess(isLive: false);
    } on WallpaperApplyException catch (e) {
      await _clearPending(prefs);
      state = WallpaperApplyError(message: e.message);
    } catch (e) {
      await _clearPending(prefs);
      // Offline is the common case here (the download), and it is not a bug —
      // the UI must not print "ClientException: Failed host lookup".
      final network = isNetworkError(e);
      state = WallpaperApplyError(
        message: network ? 'offline' : e.toString(),
        isNetwork: network,
      );
    }
  }

  Future<void> _clearPending(SharedPreferences prefs) async {
    await prefs.remove(appliedWallpaperPendingKey);
    await prefs.remove(pendingApplyPageIndexKey);
    await prefs.remove(pendingApplyCategoryKey);
    await prefs.remove(pendingApplyIsLiveKey);
  }

  void reset() => state = const WallpaperApplyIdle();
}

final wallpaperApplyProvider =
    NotifierProvider<WallpaperApplyNotifier, WallpaperApplyState>(
      WallpaperApplyNotifier.new,
    );
