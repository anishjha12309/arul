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
import '../../auth/providers/auth_providers.dart';
import '../../premium/providers/entitlement_provider.dart';
import '../../referral/data/install_referrer_service.dart';
import '../data/direct_share_service.dart';
import '../data/share_watermark_service.dart';
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
  const WallpaperShareError({
    required this.message,
    this.isNetwork = false,
    this.premiumRequired = false,
  });

  /// DIAGNOSTIC ONLY -- never shown to a user (English, and can be a raw
  /// exception). The UI localizes from [isNetwork].
  final String message;
  final bool isNetwork;

  /// The server refused because the subscription is no longer live — route to
  /// the paywall rather than showing a generic share failure.
  final bool premiumRequired;
}

// ─── Share-sheet launcher ─────────────────────────────────────────────────────

/// Thin seam over the static [SharePlus.instance] so tests can fake the system
/// share sheet (there is no platform channel in pure-Dart tests).
final shareSheetLauncherProvider =
    Provider<Future<ShareResult> Function(ShareParams)>(
      (ref) =>
          (params) => SharePlus.instance.share(params),
    );

// ─── Notifier ─────────────────────────────────────────────────────────────────

class WallpaperShareNotifier extends Notifier<WallpaperShareState> {
  @override
  WallpaperShareState build() => const WallpaperShareIdle();

  /// Downloads the media through the signed-URL gate (or reuses the cached copy
  /// the apply flow / prefetcher already put on disk) and sends it outward:
  /// straight to WhatsApp when it is installed, otherwise the system sheet.
  ///
  /// [buildCaption] renders the caption AROUND the install link, which can only
  /// be resolved mid-flow. It is a callback rather than a plain string because
  /// the caption is localized and this notifier has no `BuildContext`.
  ///
  /// It replaced a plain `message` parameter that was concatenated as
  /// `'$message\n$link'`. That was not a style preference: the message itself
  /// ended in `https://hsrapps.com/arul`, so every shared wallpaper went out
  /// carrying TWO links — the hard-coded one and the referral-attributed one —
  /// and the recipient had even odds of tapping the one that credited nobody.
  /// Putting the link INSIDE the caption makes a second one impossible to add by
  /// accident.
  ///
  /// There is no "shared" success state: the sheet is the OS's, and whether the
  /// user actually completed a share is not observable. We return to idle as
  /// soon as it is handed off — claiming success would be a lie.
  Future<void> share(
    Wallpaper wallpaper, {
    required String Function(String link) buildCaption,
  }) async {
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

      if (file != null) {
        // The bytes are already on disk (a previous apply/share, or the feed
        // prefetcher pulled them for playback), so the DOWNLOAD is skipped —
        // but the gate is not. Share sends the file OFF-DEVICE, so skipping
        // `/media/signed-url` (the only authoritative entitlement check) here
        // let a lapsed subscriber keep sharing anything already cached,
        // indefinitely — the same "cache became a permanent licence" hole the
        // apply flow closed. Proven here first, then back-ported to Pakiza the
        // same day (2026-07-29) — keep both in sync.
        try {
          await service.downloadUrl(wallpaper);
        } on WallpaperApplyException catch (e) {
          // A real 403 is the gate doing its job — surface it so the screen
          // routes to the paywall. Any other API failure on bytes we already
          // hold is not worth blocking a paying user over.
          if (e.premiumRequired) rethrow;
        } catch (e) {
          if (!isNetworkError(e)) rethrow;
          // Offline, with the file already on disk from a previously-passing
          // gate. Allow it — same trade as apply.
        }
      }

      if (file == null) {
        // The GATED download URL (Worker signed-url when the backend exists).
        final url = await service.downloadUrl(wallpaper);
        file = await service.downloadFile(url, filename, (p) {
          state = WallpaperSharePreparing(progress: p);
        });
      }

      // Watermark AFTER the source resolves, still under Preparing. Output is
      // always a NEW file — the source may be a cache entry shared with apply/
      // prefetch and must never be mutated. On any failure the ORIGINAL file is
      // shared: a missing watermark must never break the share.
      var shared = file;
      var watermarked = false;
      try {
        shared = await _watermark(wallpaper, file, tmpDir.path);
        watermarked = true;
      } on Object catch (e) {
        analytics.track(
          'share_watermark_failed',
          properties: {
            'wallpaper_id': wallpaper.id,
            'type': wallpaper.kind.name,
            'reason': e.toString(),
          },
        );
      }

      final link = await _installLink();
      final caption = buildCaption(link.url);
      final mimeType = _mimeType(shared.path);

      // Idle BEFORE the hand-off: the sheet's future resolves only when it
      // closes, so leaving Preparing set would strand the progress bar beneath
      // it.
      state = const WallpaperShareIdle();

      // WhatsApp first. It is where these wallpapers actually travel, and the
      // chooser is a tap that loses shares — but it is attempted, never
      // assumed: a false answer (not installed, or it refused the mime type) is
      // routine and falls through to the sheet below. The FILE goes with it —
      // this is a native targeted ACTION_SEND, not the text-only
      // `whatsapp://send?text=` link the referral screen uses.
      final direct = await ref
          .read(directShareServiceProvider)
          .shareToWhatsApp(
            filePath: shared.path,
            mimeType: mimeType,
            text: caption,
          );

      // `unavailable` is the honest status for the direct path: WhatsApp owns
      // the outcome from here and never reports back, exactly as the system
      // sheet doesn't when it is dismissed.
      var status = ShareResultStatus.unavailable;
      if (!direct) {
        final result = await ref.read(shareSheetLauncherProvider)(
          ShareParams(
            files: [XFile(shared.path, mimeType: mimeType)],
            // What the RECIPIENT sees (`arul-<title-slug>.<ext>`) instead of the
            // R2 object key's opaque name. The cache file is named for its
            // content, so this is where the brand goes — without forking the
            // cache. Extension follows the SHARED file (a watermarked .webp
            // re-encodes to .jpg), not the cache entry.
            fileNameOverrides: [_recipientFilename(wallpaper, shared.path)],
            text: caption,
          ),
        );
        status = result.status;
      }

      analytics.track(
        'wallpaper_shared',
        properties: {
          'wallpaper_id': wallpaper.id,
          'type': wallpaper.kind.name,
          'category': wallpaper.category,
          'result': status.name,
          'watermarked': watermarked,
          // Reach telemetry. `link_attributed` false means the outgoing share
          // carried the plain Play listing and the sender can never be credited
          // for the install — a silent referral leak that was previously
          // invisible. `channel` says whether skipping the chooser is earning
          // its keep.
          'link_attributed': link.attributed,
          'channel': direct ? 'whatsapp' : 'sheet',
        },
      );
    } on WallpaperApplyException catch (e, st) {
      if (e.premiumRequired) {
        // Expected business condition, not a defect — see
        // WallpaperApplyException.premiumRequired. No crash record; refresh the
        // stale client snapshot so the paywall the screen opens tells the truth.
        ref.invalidate(entitlementDetailProvider);
      } else {
        // Share failures gate a core premium action — record like apply does.
        crash.recordError(e, st, reason: 'wallpaper share failed');
      }
      state = WallpaperShareError(
        message: e.message,
        premiumRequired: e.premiumRequired,
      );
    } catch (e, st) {
      final network = isNetworkError(e);
      if (!network) {
        crash.recordError(e, st, reason: 'wallpaper share unexpected error');
      }
      state = WallpaperShareError(message: e.toString(), isNetwork: network);
    }
  }

  /// Produces the watermarked copy for THIS share: fresh spec (fresh code —
  /// never reused, so every outgoing copy is individually identifiable), output
  /// `<basename>-wm-<code>.<jpg|mp4>` in the temp dir. Also sweeps `-wm-` files
  /// older than a day: codes make every output unique, so they only accumulate.
  Future<File> _watermark(Wallpaper wallpaper, File src, String tmpPath) async {
    _cleanStaleWatermarks(tmpPath);

    final wm = ref.read(shareWatermarkServiceProvider);
    final spec = wm.plan(
      wallpaperId: wallpaper.id,
      userId: _currentUserIdOrNull(),
    );

    // Split on BOTH separators: Windows (tests) mixes `\` and `/` in one path.
    final srcName = src.path.split(RegExp(r'[/\\]')).last;
    final dot = srcName.lastIndexOf('.');
    final stem = dot == -1 ? srcName : srcName.substring(0, dot);

    if (wallpaper.kind == WallpaperKind.live) {
      return wm.watermarkVideo(
        src,
        spec,
        outPath: '$tmpPath/$stem-wm-${spec.code}.mp4',
      );
    }
    // Static: always re-encoded to JPEG, whatever the source (.jpg/.webp).
    return wm.watermarkImage(
      src,
      spec,
      outPath: '$tmpPath/$stem-wm-${spec.code}.jpg',
    );
  }

  /// Best-effort, fire-and-forget deletion of day-old watermarked outputs.
  void _cleanStaleWatermarks(String tmpPath) {
    final cutoff = DateTime.now().subtract(const Duration(days: 1));
    Future(() async {
      await for (final entry in Directory(tmpPath).list()) {
        if (entry is! File || !entry.path.contains('-wm-')) continue;
        try {
          if ((await entry.stat()).modified.isBefore(cutoff)) {
            await entry.delete();
          }
        } catch (_) {
          // Another share may have raced the delete — irrelevant.
        }
      }
    }).catchError((_) {});
  }

  /// The signed-in user's id if it is ALREADY known — never awaited, never a
  /// share blocker. Feeds the watermark code so a leaked copy traces to a user.
  String? _currentUserIdOrNull() {
    try {
      return ref.read(authStateStreamProvider).value?.userId;
    } catch (_) {
      return null; // auth stack unavailable (tests) — code still unique
    }
  }

  static String _mimeType(String path) {
    if (path.endsWith('.mp4')) return 'video/mp4';
    if (path.endsWith('.webp')) return 'image/webp';
    if (path.endsWith('.png')) return 'image/png';
    return 'image/jpeg';
  }

  /// The Play Store link for the share caption: referral-attributed when the
  /// user's code loads in time, otherwise the plain listing. Never blocks the
  /// share on the referral call — the file is the payload, the link is a bonus.
  ///
  /// Reports WHICH of the two it returned, because the difference is worth
  /// money: an unattributed link installs the app and credits nobody, and until
  /// this was tracked there was no way to tell how often that happened.
  Future<({String url, bool attributed})> _installLink() async {
    if (AppConfig.hasBackend) {
      try {
        final summary = await ref
            .read(referralRepositoryProvider)
            .getReferralSummary()
            .timeout(const Duration(seconds: 2));
        final code = summary.referralCode;
        if (code != null && code.isNotEmpty) {
          return (
            url: InstallReferrerService.buildShareLink(code),
            attributed: true,
          );
        }
      } catch (_) {
        // Offline mid-flow / slow server / no code — fall through.
      }
    }
    return (
      url: 'https://play.google.com/store/apps/details?id=$kPlayPackageId',
      attributed: false,
    );
  }

  /// Friendly filename shown to the recipient (`arul-<title-slug>.<ext>`),
  /// extension taken from the file actually being shared.
  String _recipientFilename(Wallpaper wallpaper, String sharedPath) {
    final dot = sharedPath.lastIndexOf('.');
    final ext = dot == -1 ? '' : sharedPath.substring(dot);
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
