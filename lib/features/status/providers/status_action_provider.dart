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
import '../../wallpapers/data/share_watermark_service.dart';
import '../../wallpapers/providers/wallpaper_share_provider.dart';
import '../data/status_media_service.dart';
import '../data/status_overlay.dart';
import '../domain/status_video.dart';
import 'status_persona_provider.dart';
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
  const StatusActionChoosing(
    this._status,
    this._file,
    this._whatsApp, [
    this._personal = (photo: false, name: false),
  ]);

  final StatusVideo _status;
  final File _file;
  final bool _whatsApp;
  final StatusPersonalised _personal;
}

/// What the outgoing clip carries of the user: their photo, their name, or neither.
typedef StatusPersonalised = ({bool photo, bool name});

extension on StatusPersonalised {
  Map<String, Object> get props => {'with_photo': photo, 'with_name': name};
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
      final source = await _source(status, StatusMediaAction.share);
      if (!ref.mounted) return null;
      state = const StatusActionBusy(stage: StatusActionStage.preparing);
      final (:file, :personal) = await _personalise(status, source);
      if (!ref.mounted) return null;
      final whatsApp = await direct.hasWhatsApp(mimeType: _mime);
      if (!ref.mounted) return null;
      state = StatusActionChoosing(status, file, whatsApp, personal);
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
      _personal: final personal,
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
            // No trace code on statuses (owner); kept so the dashboards' column stays filled.
            'watermarked': false,
            ...personal.props,
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

  // The gallery copy matches what a share sends: the user's photo and name burnt in when this phone
  // can, else the fetched clip byte for byte. Null when another action is running.
  Future<StatusActionOutcome?> save(StatusVideo status) async {
    if (state is! StatusActionIdle) return null;
    state = const StatusActionBusy();
    final analytics = ref.read(analyticsServiceProvider);
    final media = ref.read(statusMediaServiceProvider);
    try {
      final source = await _source(status, StatusMediaAction.download);
      if (ref.mounted) {
        state = const StatusActionBusy(stage: StatusActionStage.saving);
      }
      final (:file, :personal) = await _personalise(status, source);
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
              ...personal.props,
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

  /// The clip with the user's photo and name burnt in when there is something to draw and this
  /// phone can export (API 31+); otherwise [src] untouched, as every clip went out before.
  Future<({File file, StatusPersonalised personal})> _personalise(
    StatusVideo status,
    File src,
  ) async {
    const plain = (photo: false, name: false);
    StatusPersona persona;
    try {
      persona = await ref.read(statusPersonaProvider.future);
    } catch (_) {
      // No readable persona is the same as none: the clip goes out as it is.
      return (file: src, personal: plain);
    }
    final width = status.width;
    final height = status.height;
    // The PNG is placed 1:1 on the frame, so an unknown size would misplace it -> send the clip as is.
    if (!ref.mounted || width == null || height == null || width <= 0 || height <= 0) {
      return (file: src, personal: plain);
    }
    final spec = StatusOverlaySpec(
      photo: persona.shownPhoto,
      name: persona.showName ? ref.read(statusPersonaNameProvider) : null,
      slot: status.photoSlot,
      clipHeightPx: height,
    );
    if (spec.isEmpty) return (file: src, personal: plain);
    final export = ref.read(shareWatermarkServiceProvider);
    if (!(await export.videoWatermarkSupport()).supported) {
      return (file: src, personal: plain);
    }
    // The name rides in a band under the clip: the exported frame grows by it.
    final canvasHeight =
        height + (spec.band > 0 ? StatusOverlaySpec.bandPxFor(height) : 0);
    // Past 1920 tall the hardware encoder refuses the grown frame.
    if (canvasHeight > 1920) return (file: src, personal: plain);
    final png = await renderStatusOverlayPng(
      spec,
      width: width,
      height: canvasHeight,
    );
    // The export decodes AND encodes in hardware; a budget SoC fits ~2 codecs and the reel holds
    // them -> free them first and keep a swipe under the card from re-grabbing one.
    if (!ref.mounted) return (file: src, personal: plain);
    final reel = ref.read(statusVideoControllerProvider);
    await reel.holdDecoders();
    try {
      Future<File> run() => export.overlayVideo(
        src,
        png,
        outPath:
            '${src.parent.path}/status-${status.id}-me-${DateTime.now().millisecondsSinceEpoch}.mp4',
        canvasWidth: width,
        canvasHeight: canvasHeight,
        contentHeight: height,
      );
      File out;
      try {
        out = await run();
      } on ShareWatermarkUnsupportedException {
        rethrow;
      } on ShareWatermarkTimeoutException {
        // A stalled encoder stalls again: a retry would only double the wait.
        rethrow;
      } on Object {
        // One retry, as the wallpaper share does: a codec still closing from the reel fails the first try.
        await Future<void>.delayed(const Duration(milliseconds: 600));
        out = await run();
      }
      return (
        file: out,
        personal: (photo: spec.photo != null, name: spec.name != null),
      );
    } finally {
      reel.reclaimDecoders();
    }
  }

  /// The ~8 MB source copies accumulate, one per clip ever acted on -> sweep status copies over a
  /// day old (older builds' watermarked ones included); never [keep], which is about to be read.
  /// A personalised export is a fresh file per tap, so it goes after an hour.
  void _cleanStaleCopies(String dir, {required String keep}) {
    final now = DateTime.now();
    final cutoff = now.subtract(const Duration(days: 1));
    final exportCutoff = now.subtract(const Duration(hours: 1));
    Future(() async {
      await for (final entry in Directory(dir).list()) {
        if (entry is! File ||
            !entry.uri.pathSegments.last.startsWith('status-')) {
          continue;
        }
        if (entry.path == keep) continue;
        final limit = entry.uri.pathSegments.last.contains('-me-')
            ? exportCutoff
            : cutoff;
        try {
          if ((await entry.stat()).modified.isBefore(limit)) {
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
