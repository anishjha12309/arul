import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/analytics/analytics_events.dart';
import '../../../core/analytics/analytics_provider.dart';
import '../../../core/config/app_config.dart';
import '../../../core/crash/crash_provider.dart';
import '../../../core/error/app_exception.dart';
import '../../../core/providers/locale_provider.dart';
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

  /// DIAGNOSTIC ONLY — never shown to a user; English, and possibly a raw exception.
  /// The UI localizes from [isNetwork].
  final String message;
  final bool isNetwork;

  /// The server refused because the subscription is no longer live -> route to the paywall.
  final bool premiumRequired;
}

/// Thin seam over the static [SharePlus.instance] -> tests can fake the system share sheet.
final shareSheetLauncherProvider =
    Provider<Future<ShareResult> Function(ShareParams)>(
      (ref) =>
          (params) => SharePlus.instance.share(params),
    );

class WallpaperShareNotifier extends Notifier<WallpaperShareState> {
  @override
  WallpaperShareState build() => const WallpaperShareIdle();

  /// Downloads the media through the signed-URL gate, or reuses a copy already on disk.
  /// Then sends it outward — straight to WhatsApp when installed, otherwise the system sheet.
  ///
  /// [buildCaption] renders the caption AROUND the install link, resolvable only mid-flow.
  /// A callback, not a string, because the caption is localized and this notifier has no context.
  /// Concatenating `'$message\n$link'` sent TWO links, one of which credited nobody.
  /// Putting the link INSIDE the caption makes a second one impossible to add by accident.
  /// There is NO "shared" success state — the sheet is the OS's and completion is unobservable.
  /// Idle resumes as soon as it is handed off; claiming success would be a lie.
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

      // The SAME filename apply uses — a different prefix downloaded identical bytes TWICE.
      // The friendly name the recipient sees is `fileNameOverrides` below, not a renamed cache entry.
      final filename = applyCacheFilename(wallpaper);
      final tmpDir = await getTemporaryDirectory();
      final cached = File('${tmpDir.path}/$filename');

      File? file;
      if (await cached.exists() && await cached.length() > 0) {
        file = cached;
      } else {
        // Reuse the feed prefetcher's copy when it has one — for a live wallpaper it almost always does.
        // Looked up by the PUBLIC url, the prefetcher's cache key, never the one-shot signed one.
        final prefetched = await ref
            .read(wallpaperPrefetchServiceProvider)
            .cachedPathOrNull(await service.resolveUrl(wallpaper));
        if (prefetched != null) {
          try {
            file = await File(prefetched).copy(cached.path);
          } catch (_) {
            // Evicted between lookup and copy -> fall through to the download.
          }
        }
      }

      if (file != null) {
        // The bytes are already on disk -> the DOWNLOAD is skipped, but the GATE is not.
        // Share sends the file OFF-DEVICE, and `/media/signed-url` is the only real check.
        // Skipping it let a lapsed subscriber keep sharing anything cached, indefinitely.
        // The same "cache became a permanent licence" hole the apply flow closed.
        // The same fix lives in Pakiza — keep both in sync.
        try {
          await service.downloadUrl(wallpaper, action: MediaUseAction.share);
        } on WallpaperApplyException catch (e) {
          // A real 403 is the gate doing its job -> surface it and route to the paywall.
          // Any other API failure, on bytes already held, is not worth blocking a payer over.
          if (e.premiumRequired) rethrow;
        } catch (e) {
          if (!isNetworkError(e)) rethrow;
          // Offline, with the file on disk from a previously-passing gate -> allow it, as apply does.
        }
      }

      if (file == null) {
        // The GATED download URL — the Worker's signed-url when a backend exists.
        final url = await service.downloadUrl(
          wallpaper,
          action: MediaUseAction.share,
        );
        file = await service.downloadFile(url, filename, (p) {
          state = WallpaperSharePreparing(progress: p);
        });
      }

      // Watermark AFTER the source resolves, still under Preparing.
      // The output is always a NEW file — the source may be a cache entry apply also holds.
      // The two failure modes are deliberately NOT the same:
      //   · CANNOT watermark (live video below API 31) -> share the clean original, silently;
      //   · CAN watermark but did not -> FAIL the share.
      // Falling through on a capable device made the trace code worthless where it works.
      // An untraced copy left the phone with nothing recording that it had.
      // A share the user can retry is the better failure.
      var shared = file;
      var watermarked = false;
      try {
        shared = await _watermarkWithRetry(wallpaper, file, tmpDir.path);
        watermarked = true;
      } on ShareWatermarkUnsupportedException catch (e) {
        // By design and invisible to the user — the exception's doc says why API 31 is the line.
        analytics.track(
          'share_watermark_skipped',
          properties: {
            'wallpaper_id': wallpaper.id,
            'type': wallpaper.kind.name,
            'sdk_int': e.sdkInt,
          },
        );
      } on Object catch (e) {
        analytics.track(
          'share_watermark_failed',
          properties: {
            'wallpaper_id': wallpaper.id,
            'type': wallpaper.kind.name,
            'reason': e.toString(),
          },
        );
        rethrow;
      }

      final link = await _installLink(wallpaper);
      final caption = buildCaption(link.url);
      final mimeType = _mimeType(shared.path);

      // The sheet's future resolves only when it CLOSES -> go idle before the hand-off.
      // Otherwise the progress bar is stranded beneath it.
      state = const WallpaperShareIdle();

      // WhatsApp FIRST — it is where these travel, and the chooser is a tap that loses shares.
      // Attempted, never assumed: a false answer is routine and falls through to the sheet.
      // The FILE goes with it — a native targeted ACTION_SEND, not the text-only referral link.
      final direct = await ref
          .read(directShareServiceProvider)
          .shareToWhatsApp(
            filePath: shared.path,
            mimeType: mimeType,
            text: caption,
          );

      // `unavailable` is the honest status here — WhatsApp owns the outcome and never reports back.
      var status = ShareResultStatus.unavailable;
      if (!direct) {
        final result = await ref.read(shareSheetLauncherProvider)(
          ShareParams(
            files: [XFile(shared.path, mimeType: mimeType)],
            // What the RECIPIENT sees, instead of the R2 key's opaque name.
            // The cache file is named for its CONTENT -> the brand goes here, forking nothing.
            // The extension follows the SHARED file, not the cache entry — a .webp re-encodes to .jpg.
            fileNameOverrides: [_recipientFilename(wallpaper, shared.path)],
            text: caption,
          ),
        );
        status = result.status;
      }

      analytics.track(
        ArulEvents.wallpaperShared,
        properties: {
          'wallpaper_id': wallpaper.id,
          'type': wallpaper.kind.name,
          'category': wallpaper.category,
          'result': status.name,
          'watermarked': watermarked,
          // Reach telemetry. `link_attributed` false means the sender can never be credited.
          // That referral leak was previously invisible.
          // `channel` says whether skipping the chooser is earning its keep.
          'link_attributed': link.attributed,
          'channel': direct ? 'whatsapp' : 'sheet',
        },
      );
    } on WallpaperApplyException catch (e, st) {
      if (e.premiumRequired) {
        // An expected business condition, not a defect -> NO crash record.
        // Refresh the stale client snapshot so the paywall the screen opens tells the truth.
        ref.invalidate(entitlementDetailProvider);
      } else {
        // Share failures gate a core premium action -> record them, as apply does.
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

  /// One retry before a watermark failure is allowed to fail the share.
  ///
  /// The native exporter runs ONE export at a time and answers `busy` to a second.
  /// A hardware codec can also be briefly unavailable behind the feed's player pool.
  /// Neither is worth refusing a share over, now that a failure is fatal to it.
  /// The retry RE-PLANS -> the second attempt gets its own code and its own output path.
  /// An unsupported DEVICE is never retried: that answer will not change.
  Future<File> _watermarkWithRetry(
    Wallpaper wallpaper,
    File src,
    String tmpPath,
  ) async {
    try {
      return await _watermark(wallpaper, src, tmpPath);
    } on ShareWatermarkUnsupportedException {
      rethrow;
    } on Object {
      await Future<void>.delayed(const Duration(milliseconds: 600));
      return _watermark(wallpaper, src, tmpPath);
    }
  }

  /// The watermarked copy for THIS share — a fresh spec, so every outgoing copy is identifiable.
  /// Output is `<basename>-wm-<code>.<jpg|mp4>` in the temp dir.
  /// Codes make every output unique, so they only accumulate -> sweep `-wm-` files over a day old.
  Future<File> _watermark(Wallpaper wallpaper, File src, String tmpPath) async {
    _cleanStaleWatermarks(tmpPath);

    final wm = ref.read(shareWatermarkServiceProvider);
    final spec = wm.plan(
      wallpaperId: wallpaper.id,
      userId: _currentUserIdOrNull(),
    );

    // Split on BOTH separators — Windows mixes `\` and `/` in one path.
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
    // Static: ALWAYS re-encoded to JPEG, whatever the source.
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

  /// The signed-in user's id if ALREADY known — never awaited, never a share blocker.
  /// Feeds the watermark code, so a leaked copy traces to a user.
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

  /// The ONE link a share caption carries (docs/share.md) — an App Link to THIS wallpaper.
  /// Referral-attributed when the user's code loads in time.
  ///
  /// Points at the WALLPAPER, not the listing -> a recipient who has the app lands on it.
  /// One who does not still installs: `/w/:id` redirects to Play carrying the id, and it reopens.
  /// The same URL shape ad creatives use.
  /// NEVER blocks the share on the referral call — the file is the payload, the link a bonus.
  /// Reports WHICH of the two it returned, because an unattributed link credits nobody.
  Future<({String url, bool attributed})> _installLink(
    Wallpaper wallpaper,
  ) async {
    // The caption goes out in the sharer's language -> a fresh install should open in it.
    // As `ilang`, which survives only the Play referrer, never the App Link.
    // A recipient who already has Arul keeps their OWN language.
    final installLang = ref.read(localeProvider).languageCode;
    if (AppConfig.hasBackend) {
      try {
        final summary = await ref
            .read(referralRepositoryProvider)
            .getReferralSummary()
            .timeout(const Duration(seconds: 2));
        final code = summary.referralCode;
        if (code != null && code.isNotEmpty) {
          return (
            url: InstallReferrerService.buildWallpaperLink(
              wallpaper.id,
              code: code,
              installLang: installLang,
            ),
            attributed: true,
          );
        }
      } catch (_) {
        // Offline mid-flow, a slow server, or no code -> fall through.
      }
    }
    // Still the wallpaper link, uncredited — losing attribution must not also cost the deep link.
    return (
      url: InstallReferrerService.buildWallpaperLink(
        wallpaper.id,
        installLang: installLang,
      ),
      attributed: false,
    );
  }

  /// Friendly filename shown to the recipient, its extension taken from the file actually shared.
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
