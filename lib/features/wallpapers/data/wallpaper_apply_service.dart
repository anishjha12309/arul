import 'dart:io';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../../../core/api/api_client.dart';
import '../../../core/config/app_config.dart';
import '../../../data/models/wallpaper.dart';

// ─── Target enum ─────────────────────────────────────────────────────────────

/// Where on the device the wallpaper should be applied.
enum ApplyTarget {
  home,
  lock,
  both;

  /// Wire value passed to the native apply channel ("home" | "lock" | "both").
  String get channelValue => name;
}

// ─── Exception ───────────────────────────────────────────────────────────────

class WallpaperApplyException implements Exception {
  const WallpaperApplyException(
    this.message, {
    this.premiumRequired = false,
    this.code,
  });
  final String message;

  /// The native `PlatformException.code` when this came from the apply channel
  /// (`unsupported` | `manufacturerRestriction` | `permissionDenied` |
  /// `sourceNotFound` | `applyFailed` | `unknown`), null otherwise.
  ///
  /// It used to be discarded at the channel boundary, which left every apply
  /// failure looking identical to every sink. `wallpaper_apply_failed` reports
  /// it, and that is the only reason it is threaded through — the UI still
  /// maps failures to one localized line and must not branch on it. `unsupported`
  /// in particular means two different things depending on which native method
  /// raised it (no live-wallpaper feature vs. WallpaperManager unsupported), so
  /// it is a diagnostic label, never a decision.
  final String? code;

  /// The Worker refused with 403 `premium_required`.
  ///
  /// This is an ordinary business condition, not a defect: entitlement is read
  /// live from Neon on every gated call, so a subscription that lapsed (or was
  /// refunded) mid-session lands here while the client still believes it is
  /// premium. Callers must route to the paywall and must NOT file a Crashlytics
  /// non-fatal — doing so would bury real apply failures under expected ones.
  final bool premiumRequired;

  @override
  String toString() => message;
}

// ─── Live apply outcome ─────────────────────────────────────────────

/// What the native side actually did with a live apply.
///
/// The channel used to answer `null` for both, which made "the chooser is open
/// over us" and "this device can't do live at all, so we applied the poster
/// frame" indistinguishable — and they need opposite handling: one is an
/// unobservable hand-off, the other is a finished, confirmed apply.
enum LiveApplyOutcome {
  /// The system live-wallpaper chooser opened. The user's "Set" tap happens in
  /// an activity we cannot observe, so this is NEVER a success claim.
  chooser,

  /// Live apply is impossible on this device, so the native side applied the
  /// clip's first frame as a static wallpaper. Already done when we get here.
  staticFallback,
}

/// [LiveApplyOutcome] plus, for the fallback, WHY it was impossible.
class LiveApplyResult {
  const LiveApplyResult(this.outcome, {this.reason});

  final LiveApplyOutcome outcome;

  /// `featureMissing` | `chooserUnavailable` on [LiveApplyOutcome.staticFallback],
  /// null otherwise. Reported as-is so the over-fire tripwire
  /// (`wallpaper_apply_live_fallback`) can be split by cause.
  final String? reason;
}

// ─── Gated action ────────────────────────────────────────────────────────────

/// Which gated action a `/media/signed-url` grant is for.
///
/// The Worker uses it for ONE thing: deciding whether the grant counts toward
/// the row's popularity score. Both values are still fully gated — this never
/// widens or narrows the premium check.
enum MediaUseAction {
  /// Applying the wallpaper to the device. Counts toward `apply_count`.
  apply,

  /// Sharing the file to another app. Deliberately does NOT count — a share is
  /// reach, not use, and folding it in would rank a wallpaper nobody kept.
  share;

  /// Wire value sent as the request's `action` field.
  String get wire => name;
}

// ─── Interface ───────────────────────────────────────────────────────────────

abstract class WallpaperApplyService {
  /// The PUBLIC CDN URL for [w]'s media. Used as the prefetch-cache lookup key
  /// (the feed prefetcher caches by this URL) — NOT necessarily the URL the
  /// gated download uses; see [downloadUrl].
  Future<String> resolveUrl(Wallpaper w);

  /// The URL the gated apply/share download actually fetches: the Worker's
  /// `POST /media/signed-url` — the REAL premium gate: a live entitlement read
  /// returning a short-lived signed URL. Only a define-less local run (no
  /// backend) degrades to the public CDN object.
  ///
  /// [action] tells the Worker which gated action this grant is for. It is NOT
  /// cosmetic: only `apply` increments `wallpapers.apply_count`, which is the
  /// order of the All feed. Passing `apply` on the share path would make every
  /// share look like an apply and rank shared-but-unapplied wallpapers to the
  /// top. Callers must pass their real action; the Worker counts neither when it
  /// is absent.
  Future<String> downloadUrl(Wallpaper w, {required MediaUseAction action});

  /// Downloads [url] to a temp file named [filename]. [onProgress] gets 0.0→1.0.
  Future<File> downloadFile(
    String url,
    String filename,
    void Function(double) onProgress,
  );

  /// Applies [file] as a static wallpaper to [target] screen(s).
  Future<void> applyStaticWallpaper(File file, ApplyTarget target);

  /// Sets [file] (an MP4) as a live wallpaper: the native side persists the
  /// video, then ALWAYS opens the system live-wallpaper preview/chooser, where
  /// the user makes the final "Set wallpaper" tap — every apply, even when our
  /// service is already active (deliberate product decision; no silent in-place
  /// swap).
  ///
  /// Returns [LiveApplyOutcome.staticFallback] instead when the device cannot
  /// run live wallpapers AT ALL (no platform feature, or no activity handles
  /// either chooser intent): the native side has already applied the clip's
  /// first frame as a static wallpaper, and that outcome is finished, not a
  /// hand-off. Throws [WallpaperApplyException] on a real failure.
  Future<LiveApplyResult> applyLiveWallpaper(File file, ApplyTarget target);
}

// ─── CDN-backed implementation ───────────────────────────────────────────────

class CdnWallpaperApplyService implements WallpaperApplyService {
  CdnWallpaperApplyService({
    ApiClient? apiClient,
    http.Client? httpClient,
    MethodChannel? channel,
  }) : _api = apiClient,
       _http = httpClient ?? http.Client(),
       _channel = channel ?? const MethodChannel(_channelName);

  static const _channelName = 'com.hsrutility.arul/wallpaper';

  /// Test seam for the static fallback: `featureMissing` | `chooserUnavailable`
  /// forces that reason on a device that is perfectly capable of live
  /// wallpapers, so both branches can be walked without a Redmi.
  ///
  ///     flutter run --dart-define-from-file=env/dev.json \
  ///       --dart-define=DEBUG_LIVE_WALLPAPER_FALLBACK=featureMissing
  ///
  /// Double-gated and dead in release: `kDebugMode` keeps the argument out of
  /// the call here, and the native side ignores it unless `BuildConfig.DEBUG`.
  static const _debugForceFallback = String.fromEnvironment(
    'DEBUG_LIVE_WALLPAPER_FALLBACK',
  );

  /// Present only when the Worker exists — drives the signed-url gate.
  final ApiClient? _api;

  final http.Client _http;

  /// Our own channel (com.hsrutility.arul.wallpaper.WallpaperApplyChannel) — there
  /// is no third-party wallpaper plugin in this app.
  final MethodChannel _channel;

  @override
  Future<String> resolveUrl(Wallpaper w) async => w.url(AppConfig.cdnBaseUrl);

  @override
  Future<String> downloadUrl(
    Wallpaper w, {
    required MediaUseAction action,
  }) async {
    final api = _api;
    if (api == null || !AppConfig.hasBackend) {
      // Defensive: unreachable in shipped builds (API_BASE_URL is always set).
      // Kept for define-less local runs — keys are public by design (soft
      // gate).
      return w.url(AppConfig.cdnBaseUrl);
    }
    try {
      final data = await api.post(
        '/media/signed-url',
        body: {'id': w.id, 'kind': 'wallpaper', 'action': action.wire},
      );
      final url = data['url'] as String?;
      if (url == null || url.isEmpty) {
        throw const WallpaperApplyException('Invalid signed URL response');
      }
      return url;
    } on ApiException catch (e) {
      if (e.isPremiumRequired) {
        throw const WallpaperApplyException(
          'Premium subscription required',
          premiumRequired: true,
        );
      }
      throw WallpaperApplyException('Failed to get signed URL (${e.status})');
    }
  }

  @override
  Future<File> downloadFile(
    String url,
    String filename,
    void Function(double) onProgress,
  ) async {
    final request = http.Request('GET', Uri.parse(url));
    final response = await _http.send(request);

    if (response.statusCode != 200) {
      throw WallpaperApplyException(
        'Download failed (HTTP ${response.statusCode})',
      );
    }

    final total = response.contentLength;
    int received = 0;

    final tmpDir = await getTemporaryDirectory();
    final file = File('${tmpDir.path}/$filename');

    // Download to a `.part` file and rename only on success.
    //
    // Streaming straight into the final path meant a network drop mid-download
    // left a TRUNCATED file under the real name — and the apply flow's cache check
    // ("exists and non-empty") accepted it forever after. A static apply would then
    // fail to decode every single time; a live apply would hand a broken MP4 to the
    // wallpaper service, whose error recovery re-prepares without bound — an
    // infinite prepare/error loop running on the user's home screen, unfixable
    // except by clearing app data. The rename is atomic, so the final name only
    // ever exists as a complete file.
    final part = File('${file.path}.part');
    final sink = part.openWrite();

    try {
      await response.stream.listen((List<int> chunk) {
        sink.add(chunk);
        received = received + chunk.length;
        if (total != null && total > 0) {
          onProgress(received / total);
        }
      }, cancelOnError: true).asFuture<void>();
      await sink.flush();
      await sink.close();

      // A connection cut mid-body still delivers a 200 and a short stream, so
      // trust the promised length, not the status code.
      if (total != null && total > 0 && received < total) {
        throw const WallpaperApplyException('Download incomplete');
      }

      await part.rename(file.path);
      return file;
    } catch (_) {
      try {
        await sink.close();
      } catch (_) {
        // Already closed by the success path, or the sink is dead. Either way the
        // .part file below is what matters.
      }
      if (await part.exists()) await part.delete();
      rethrow;
    }
  }

  @override
  Future<void> applyStaticWallpaper(File file, ApplyTarget target) async {
    try {
      // Native ImageWallpaperManager: setStream + OEM lock/both fallback, source
      // normalized first so a 4K source can't OOM a budget SoC. Returns null on
      // success; throws PlatformException(code, message) on failure.
      await _channel.invokeMethod<void>('setImageWallpaper', {
        'filePath': file.path,
        'target': target.channelValue,
      });
    } on PlatformException catch (e) {
      throw WallpaperApplyException(
        e.message ?? 'Failed to apply wallpaper (${e.code})',
        code: e.code,
      );
    }
  }

  @override
  Future<LiveApplyResult> applyLiveWallpaper(
    File file,
    ApplyTarget target,
  ) async {
    try {
      // The native side copies the MP4 into app-internal storage (persistent,
      // so the running wallpaper service reads a local file forever), saves the
      // service config, and opens the live-wallpaper preview/chooser. The
      // chooser owns the final home/lock decision, so [target] is not
      // forwarded for live (kept in the signature for symmetry).
      final result = await _channel
          .invokeMapMethod<String, Object?>('setVideoWallpaper', {
            'filePath': file.path,
            'enableAudio': false,
            'loop': true,
            if (kDebugMode && _debugForceFallback.isNotEmpty)
              'debugForceFallback': _debugForceFallback,
          });
      if (result?['outcome'] == 'staticFallback') {
        return LiveApplyResult(
          LiveApplyOutcome.staticFallback,
          reason: result?['reason'] as String?,
        );
      }
      // Anything else is the product path. Deliberately the default: an
      // unrecognised (or null, pre-fallback) payload must read as "the chooser
      // is open", never as "we quietly applied a still image".
      return const LiveApplyResult(LiveApplyOutcome.chooser);
    } on PlatformException catch (e) {
      throw WallpaperApplyException(
        e.message ?? 'Failed to set live wallpaper (${e.code})',
        code: e.code,
      );
    }
  }
}
