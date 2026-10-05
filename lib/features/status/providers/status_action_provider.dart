import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/analytics/analytics_provider.dart';
import '../../../core/config/app_config.dart';
import '../../../core/crash/crash_provider.dart';
import '../../../core/deeplink/install_referrer_service.dart';
import '../../../core/error/app_exception.dart';
import '../../../core/providers/locale_provider.dart';
import '../../auth/providers/auth_providers.dart';
import '../../premium/providers/entitlement_provider.dart';
import '../../wallpapers/data/direct_share_service.dart';
import '../../wallpapers/data/share_watermark_service.dart';
import '../../wallpapers/providers/wallpaper_share_provider.dart';
import '../data/status_media_service.dart';
import '../domain/status_video.dart';
import 'status_providers.dart';

sealed class StatusActionState {
  const StatusActionState();
}

final class StatusActionIdle extends StatusActionState {
  const StatusActionIdle();
}

final class StatusActionBusy extends StatusActionState {
  const StatusActionBusy({this.progress});

  final double? progress;
}

/// What the screen tells the user once an action settles; the hand-off itself is never a success
/// claim, because WhatsApp and the sheet own that outcome.
enum StatusActionOutcome {
  done,
  premiumRequired,
  permissionDenied,
  offline,
  failed,
}

/// Where status clips are written before they leave — the temp dir, a seam for tests.
final statusTempDirProvider = FutureProvider<Directory>(
  (_) => getTemporaryDirectory(),
);

class StatusActionNotifier extends Notifier<StatusActionState> {
  @override
  StatusActionState build() => const StatusActionIdle();

  /// WhatsApp's status composer first, a WhatsApp chat next, the system sheet last.
  /// [buildCaption] wraps the ONE `/s/` link for the chat and sheet paths; the composer takes none.
  /// Null when another action is already running.
  Future<StatusActionOutcome?> shareToWhatsApp(
    StatusVideo status, {
    required String Function(String link) buildCaption,
  }) async {
    if (state is StatusActionBusy) return null;
    state = const StatusActionBusy();
    try {
      final source = await _source(status, StatusMediaAction.share);
      final (file, watermarked) = await _watermarked(status, source);
      // The sheet's future resolves only when it CLOSES -> go idle before the hand-off.
      state = const StatusActionIdle();

      final direct = ref.read(directShareServiceProvider);
      var channel = 'status';
      var result = ShareResultStatus.unavailable;
      if (!await direct.shareToStatus(filePath: file.path)) {
        final caption = buildCaption(_link(status));
        channel = 'chat';
        if (!await direct.shareToWhatsApp(
          filePath: file.path,
          mimeType: 'video/mp4',
          text: caption,
        )) {
          channel = 'sheet';
          final shared = await ref.read(shareSheetLauncherProvider)(
            ShareParams(
              files: [XFile(file.path, mimeType: 'video/mp4')],
              fileNameOverrides: [_recipientFilename(status)],
              text: caption,
            ),
          );
          result = shared.status;
        }
      }
      ref
          .read(analyticsServiceProvider)
          .track(
            'status_shared',
            properties: {
              'status_id': status.id,
              'category': status.category,
              'result': result.name,
              'watermarked': watermarked,
              'channel': channel,
            },
          );
      return StatusActionOutcome.done;
    } catch (e, st) {
      return _fail(e, st, reason: 'status share failed');
    }
  }

  /// Saves the watermarked clip into the phone's Movies/Arul. Null when another action is running.
  Future<StatusActionOutcome?> save(StatusVideo status) async {
    if (state is StatusActionBusy) return null;
    state = const StatusActionBusy();
    final analytics = ref.read(analyticsServiceProvider);
    try {
      final source = await _source(status, StatusMediaAction.download);
      final (file, watermarked) = await _watermarked(status, source);
      final saved = await ref
          .read(statusMediaServiceProvider)
          .saveToGallery(file.path, _recipientFilename(status, unique: true));
      state = const StatusActionIdle();
      switch (saved.outcome) {
        case StatusSaveOutcome.saved:
          analytics.track(
            'status_saved',
            properties: {
              'status_id': status.id,
              'category': status.category,
              'watermarked': watermarked,
            },
          );
          return StatusActionOutcome.done;
        case StatusSaveOutcome.permissionDenied:
          analytics.track(
            'status_save_failed',
            properties: {'status_id': status.id, 'reason': 'permission_denied'},
          );
          return StatusActionOutcome.permissionDenied;
        case StatusSaveOutcome.failed:
          analytics.track(
            'status_save_failed',
            properties: {
              'status_id': status.id,
              'reason': saved.reason ?? 'unknown',
            },
          );
          return StatusActionOutcome.failed;
      }
    } catch (e, st) {
      final outcome = _fail(e, st, reason: 'status save failed');
      if (outcome != StatusActionOutcome.premiumRequired) {
        analytics.track(
          'status_save_failed',
          properties: {
            'status_id': status.id,
            'reason': outcome == StatusActionOutcome.offline
                ? 'network'
                : _clip(e.runtimeType.toString()),
          },
        );
      }
      return outcome;
    }
  }

  StatusActionOutcome _fail(Object e, StackTrace st, {required String reason}) {
    state = const StatusActionIdle();
    if (e is StatusMediaException && e.premiumRequired) {
      // An expected business condition -> no crash record; refresh the snapshot the paywall reads.
      ref.invalidate(entitlementDetailProvider);
      return StatusActionOutcome.premiumRequired;
    }
    if (isNetworkError(e)) return StatusActionOutcome.offline;
    ref.read(crashReporterProvider).recordError(e, st, reason: reason);
    return StatusActionOutcome.failed;
  }

  /// The clip's bytes on disk, behind a live gate read every time — the prefetched or earlier copy
  /// skips only the DOWNLOAD. Offline with bytes already held is the one allowed pass-through.
  Future<File> _source(StatusVideo status, StatusMediaAction action) async {
    final media = ref.read(statusMediaServiceProvider);
    final tmp = await ref.read(statusTempDirProvider.future);
    final cached = File('${tmp.path}/status-${status.id}.mp4');

    File? file;
    if (await cached.exists() && await cached.length() > 0) {
      file = cached;
    } else {
      final prefetched = await ref
          .read(statusPrefetchServiceProvider)
          .cachedPathOrNull(status.url(AppConfig.cdnBaseUrl));
      if (prefetched != null) {
        try {
          file = await File(prefetched).copy(cached.path);
        } catch (_) {
          // Evicted between lookup and copy -> fall through to the download.
        }
      }
    }

    if (file != null) {
      try {
        await media.signedUrl(status, action);
      } on StatusMediaException catch (e) {
        if (e.premiumRequired) rethrow;
      } catch (e) {
        if (!isNetworkError(e)) rethrow;
      }
      return file;
    }

    final url = await media.signedUrl(status, action);
    return media.downloadFile(url, cached.path, (p) {
      if (ref.mounted) state = StatusActionBusy(progress: p);
    });
  }

  /// The traced copy, or the clean original where video cannot be watermarked (below API 31).
  /// On a capable device a failure fails the action, exactly as a wallpaper share does.
  Future<(File, bool)> _watermarked(StatusVideo status, File src) async {
    try {
      return (await _watermarkWithRetry(status, src), true);
    } on ShareWatermarkUnsupportedException {
      return (src, false);
    }
  }

  /// One retry: the exporter answers `busy` while another export runs.
  Future<File> _watermarkWithRetry(StatusVideo status, File src) async {
    try {
      return await _watermark(status, src);
    } on ShareWatermarkUnsupportedException {
      rethrow;
    } on Object {
      await Future<void>.delayed(const Duration(milliseconds: 600));
      return _watermark(status, src);
    }
  }

  Future<File> _watermark(StatusVideo status, File src) async {
    final wm = ref.read(shareWatermarkServiceProvider);
    final spec = wm.plan(wallpaperId: status.id, userId: _userIdOrNull());
    final dir = src.parent.path;
    _cleanStaleWatermarks(dir);
    return wm.watermarkVideo(
      src,
      spec,
      outPath: '$dir/status-${status.id}-wm-${spec.code}.mp4',
    );
  }

  /// Every output is unique, so they only accumulate -> sweep status copies over a day old.
  void _cleanStaleWatermarks(String dir) {
    final cutoff = DateTime.now().subtract(const Duration(days: 1));
    Future(() async {
      await for (final entry in Directory(dir).list()) {
        if (entry is! File || !entry.path.contains('status-')) continue;
        if (!entry.path.contains('-wm-')) continue;
        try {
          if ((await entry.stat()).modified.isBefore(cutoff)) {
            await entry.delete();
          }
        } catch (_) {
          // Another action may have raced the delete — irrelevant.
        }
      }
    }).catchError((_) {});
  }

  String? _userIdOrNull() {
    try {
      return ref.read(authStateStreamProvider).value?.userId;
    } catch (_) {
      return null;
    }
  }

  /// The share caption's ONE link, in the sharer's language for a fresh install only.
  String _link(StatusVideo status) => InstallReferrerService.buildStatusLink(
    status.id,
    installLang: ref.read(localeProvider).languageCode,
  );

  String _recipientFilename(StatusVideo status, {bool unique = false}) {
    var slug = status.title
        .toLowerCase()
        .replaceAll(RegExp('[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    if (slug.isEmpty) slug = 'status';
    if (slug.length > 40) slug = slug.substring(0, 40);
    final suffix = unique ? '-${DateTime.now().millisecondsSinceEpoch}' : '';
    return 'arul-$slug$suffix.mp4';
  }

  static String _clip(String s) => s.length <= 100 ? s : s.substring(0, 100);
}

final statusActionProvider =
    NotifierProvider<StatusActionNotifier, StatusActionState>(
      StatusActionNotifier.new,
    );
