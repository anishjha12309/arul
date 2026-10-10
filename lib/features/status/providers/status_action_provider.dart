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
import '../../premium/providers/entitlement_provider.dart';
import '../../wallpapers/data/direct_share_service.dart';
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

// [progress] is the real download, null while none runs -> the card draws no bar for a clip on disk.
final class StatusActionBusy extends StatusActionState {
  const StatusActionBusy({
    this.stage = StatusActionStage.fetching,
    this.progress,
  });

  final StatusActionStage stage;
  final double? progress;
}

// The clip is on disk and the sheet is up: still not idle, so a second tap waits.
final class StatusActionChoosing extends StatusActionState {
  const StatusActionChoosing(this._status, this._file, this._whatsApp);

  final StatusVideo _status;
  final File _file;
  final bool _whatsApp;
}

// WhatsApp is opening: the sheet ignores taps on its way out, so a fast second tap reaches the reel.
final class StatusActionSending extends StatusActionState {
  const StatusActionSending();
}

enum StatusActionStage { fetching, preparing, saving }

// Groups and WhatsApp open the same picker (no public intent opens a groups-only one); [channel]
// keeps them apart so the owner can see which label earns taps.
enum StatusShareTarget {
  groups('groups'),
  chat('chat'),
  status('status'),
  more('sheet');

  const StatusShareTarget(this.channel);

  final String channel;
}

sealed class StatusSharePrep {
  const StatusSharePrep();
}

final class StatusShareReady extends StatusSharePrep {
  const StatusShareReady({required this.whatsApp});

  final bool whatsApp;
}

final class StatusShareSettled extends StatusSharePrep {
  const StatusShareSettled(this.outcome);

  final StatusActionOutcome outcome;
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

  // Fetch before the pick (owner's order: card, then sheet). Null when another action runs.
  Future<StatusSharePrep?> prepareShare(StatusVideo status) async {
    if (state is! StatusActionIdle) return null;
    state = const StatusActionBusy();
    final direct = ref.read(directShareServiceProvider);
    try {
      final file = await _source(status, StatusMediaAction.share);
      if (!ref.mounted) return null;
      state = const StatusActionBusy(stage: StatusActionStage.preparing);
      final whatsApp = await direct.hasWhatsApp(mimeType: _mime);
      if (!ref.mounted) return null;
      state = StatusActionChoosing(status, file, whatsApp);
      return StatusShareReady(whatsApp: whatsApp);
    } catch (e, st) {
      return StatusShareSettled(_fail(e, st, reason: 'status share failed'));
    }
  }

  // A false from a targeted intent is routine and falls to the next; the fallback chain lives in
  // docs/share.md §Status clips. The caption is the link ALONE (owner): nothing is said over a
  // clip the recipient is already watching. Null when nothing was prepared.
  Future<StatusActionOutcome?> shareVia(StatusShareTarget target) async {
    if (state case StatusActionChoosing(
      _status: final status,
      _file: final file,
      _whatsApp: final whatsApp,
    )) {
      state = const StatusActionSending();
      final direct = ref.read(directShareServiceProvider);
      final launchSheet = ref.read(shareSheetLauncherProvider);
      final analytics = ref.read(analyticsServiceProvider);
      final caption = _link(status);
      try {
        String? via;
        if (target == StatusShareTarget.status) {
          if (await direct.shareToStatus(filePath: file.path)) {
            via = 'composer';
          } else if (await direct.sendToStatus(
            filePath: file.path,
            mimeType: _mime,
          )) {
            via = 'send_to_status';
          }
        }
        if (via == null &&
            target != StatusShareTarget.more &&
            await direct.shareToWhatsApp(
              filePath: file.path,
              mimeType: _mime,
              text: caption,
            )) {
          via = 'picker';
        }
        var result = ShareResultStatus.unavailable;
        if (via == null) {
          via = 'sheet';
          // The system sheet's future resolves only when it CLOSES -> go idle before the hand-off.
          _idle();
          final shared = await launchSheet(
            ShareParams(
              files: [XFile(file.path, mimeType: _mime)],
              fileNameOverrides: [_recipientFilename(status)],
              text: caption,
            ),
          );
          result = shared.status;
        }
        analytics.track(
          'status_shared',
          properties: {
            'status_id': status.id,
            'category': status.category,
            'result': result.name,
            // Status clips go out clean (owner); kept so the dashboards' column stays filled.
            'watermarked': false,
            'channel': target.channel,
            'via': via,
            // More and "no WhatsApp at all" both read channel=sheet; this tells them apart.
            'has_whatsapp': whatsApp,
          },
        );
        return StatusActionOutcome.done;
      } catch (e, st) {
        return _fail(e, st, reason: 'status share failed');
      } finally {
        if (state is StatusActionSending) _idle();
      }
    }
    return null;
  }

  // The sheet closed with no pick -> nothing left, so nothing is tracked.
  void dismissShare() {
    if (state is StatusActionChoosing) _idle();
  }

  // Byte for byte: the gallery file is the fetched clip. Null when another action is running.
  Future<StatusActionOutcome?> save(StatusVideo status) async {
    if (state is! StatusActionIdle) return null;
    state = const StatusActionBusy();
    final analytics = ref.read(analyticsServiceProvider);
    final media = ref.read(statusMediaServiceProvider);
    try {
      final file = await _source(status, StatusMediaAction.download);
      if (ref.mounted) {
        state = const StatusActionBusy(stage: StatusActionStage.saving);
      }
      final saved = await media.saveToGallery(
        file.path,
        _recipientFilename(status, unique: true),
      );
      _idle();
      switch (saved.outcome) {
        case StatusSaveOutcome.saved:
          analytics.track(
            'status_saved',
            properties: {
              'status_id': status.id,
              'category': status.category,
              'watermarked': false,
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

  void _idle() {
    if (ref.mounted) state = const StatusActionIdle();
  }

  StatusActionOutcome _fail(Object e, StackTrace st, {required String reason}) {
    _idle();
    if (!ref.mounted) return StatusActionOutcome.failed;
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
    _cleanStaleCopies(tmp.path, keep: cached.path);

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

  /// The ~8 MB source copies accumulate, one per clip ever acted on -> sweep status copies over a
  /// day old (older builds' watermarked ones included); never [keep], which is about to be read.
  void _cleanStaleCopies(String dir, {required String keep}) {
    final cutoff = DateTime.now().subtract(const Duration(days: 1));
    Future(() async {
      await for (final entry in Directory(dir).list()) {
        if (entry is! File ||
            !entry.uri.pathSegments.last.startsWith('status-')) {
          continue;
        }
        if (entry.path == keep) continue;
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

  /// The share caption: ONE link, in the sharer's language for a fresh install only.
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

  static const _mime = 'video/mp4';

  static String _clip(String s) => s.length <= 100 ? s : s.substring(0, 100);
}

final statusActionProvider =
    NotifierProvider<StatusActionNotifier, StatusActionState>(
      StatusActionNotifier.new,
    );
