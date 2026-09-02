import 'dart:io';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../../../core/api/api_client.dart';
import '../../../core/config/app_config.dart';
import '../../../data/models/wallpaper.dart';

/// Where on the device the wallpaper should be applied.
enum ApplyTarget {
  home,
  lock,
  both;

  /// Wire value passed to the native apply channel ("home" | "lock" | "both").
  String get channelValue => name;
}

class WallpaperApplyException implements Exception {
  const WallpaperApplyException(
    this.message, {
    this.premiumRequired = false,
    this.code,
  });
  final String message;

  /// The native `PlatformException.code` from the apply channel; null otherwise.
  ///
  /// Discarded at the boundary, every apply failure looked identical to every sink.
  /// `wallpaper_apply_failed` reports it — the ONLY reason it is threaded through.
  /// The UI still maps failures to one localized line and must NOT branch on it.
  /// `unsupported` means two different things depending on which native method raised it.
  /// So it is a diagnostic label, never a decision.
  final String? code;

  /// The Worker refused with 403 `premium_required`.
  ///
  /// An ordinary business condition, not a defect — entitlement is read live on every gated call.
  /// A lapse or refund mid-session lands here while the client still believes it is premium.
  /// Callers route to the paywall and must NOT file a Crashlytics non-fatal.
  /// Doing so would bury real apply failures under expected ones.
  final bool premiumRequired;

  @override
  String toString() => message;
}

/// What the native side actually did with a live apply.
///
/// One outcome is an unobservable hand-off, the other a finished, confirmed apply.
/// A single `null` answer made them indistinguishable, and they need OPPOSITE handling.
enum LiveApplyOutcome {
  /// The system live-wallpaper chooser opened.
  /// The "Set" tap happens in an activity we cannot observe -> NEVER a success claim.
  chooser,

  /// Live apply is impossible here -> the native side applied the clip's first frame, statically.
  /// Already done by the time we get here.
  staticFallback,
}

/// [LiveApplyOutcome] plus, for the fallback, WHY it was impossible.
class LiveApplyResult {
  const LiveApplyResult(this.outcome, {this.reason});

  final LiveApplyOutcome outcome;

  /// `featureMissing` | `chooserUnavailable` on a static fallback, null otherwise.
  /// Reported as-is -> the over-fire tripwire can be split by cause.
  final String? reason;
}

/// Which gated action a `/media/signed-url` grant is for.
///
/// The Worker uses it for ONE thing — whether the grant counts toward the row's popularity.
/// Both values are still fully gated; this never widens or narrows the premium check.
enum MediaUseAction {
  /// Applying the wallpaper to the device. Counts toward `apply_count`.
  apply,

  /// Sharing the file to another app. Deliberately does NOT count.
  /// A share is reach, not use -> folding it in would rank a wallpaper nobody kept.
  share;

  /// Wire value sent as the request's `action` field.
  String get wire => name;
}

abstract class WallpaperApplyService {
  /// The PUBLIC CDN URL for [w]'s media — the prefetch-cache lookup key.
  /// NOT necessarily the URL the gated download uses; see [downloadUrl].
  Future<String> resolveUrl(Wallpaper w);

  /// The URL the gated download actually fetches — the Worker's `POST /media/signed-url`.
  ///
  /// The REAL premium gate: a live entitlement read returning a short-lived signed URL.
  /// Only a define-less local run degrades to the public CDN object.
  /// [action] is NOT cosmetic — only `apply` increments the counter that orders the All feed.
  /// Passing `apply` on the share path would rank shared-but-unapplied wallpapers to the top.
  /// Callers must pass their REAL action; the Worker counts neither when it is absent.
  Future<String> downloadUrl(Wallpaper w, {required MediaUseAction action});

  /// Downloads [url] to a temp file named [filename]. [onProgress] gets 0.0→1.0.
  Future<File> downloadFile(
    String url,
    String filename,
    void Function(double) onProgress,
  );

  /// Applies [file] as a static wallpaper to [target] screen(s).
  Future<void> applyStaticWallpaper(File file, ApplyTarget target);

  /// Sets [file] as a live wallpaper — the native side persists the video, then opens the chooser.
  ///
  /// ALWAYS the chooser, even when our service is already active -> no silent in-place swap.
  /// The user's final "Set wallpaper" tap happens there, on every apply.
  /// [LiveApplyOutcome.staticFallback] instead when the device cannot run live wallpapers AT ALL.
  /// The first frame is already applied by then — a finished outcome, not a hand-off.
  /// Throws [WallpaperApplyException] on a real failure.
  Future<LiveApplyResult> applyLiveWallpaper(File file, ApplyTarget target);
}

class CdnWallpaperApplyService implements WallpaperApplyService {
  CdnWallpaperApplyService({
    ApiClient? apiClient,
    http.Client? httpClient,
    MethodChannel? channel,
  }) : _api = apiClient,
       _http = httpClient ?? http.Client(),
       _channel = channel ?? const MethodChannel(_channelName);

  static const _channelName = 'com.hsrutility.arul/wallpaper';

  /// Test seam for the static fallback — forces a reason on a device that CAN do live wallpapers.
  /// So both branches are walkable without the hardware.
  ///
  ///     --dart-define=DEBUG_LIVE_WALLPAPER_FALLBACK=featureMissing
  ///
  /// Double-gated and dead in release: `kDebugMode` here, and `BuildConfig.DEBUG` natively.
  static const _debugForceFallback = String.fromEnvironment(
    'DEBUG_LIVE_WALLPAPER_FALLBACK',
  );

  /// Present only when the Worker exists — drives the signed-url gate.
  final ApiClient? _api;

  final http.Client _http;

  /// Our own channel — there is no third-party wallpaper plugin in this app.
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
      // Unreachable in shipped builds — API_BASE_URL is always set.
      // Kept for define-less local runs; the keys are public by design, a soft gate.
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

    // Download to a `.part` file and rename only on SUCCESS.
    //
    // Streaming into the final path left a TRUNCATED file under the real name on any drop.
    // The apply flow's "exists and non-empty" cache check then accepted it forever after.
    // A static apply failed to decode every time; a live apply handed the service a broken MP4.
    // Its error recovery re-prepares without bound — an infinite loop on the user's home screen.
    // The rename is ATOMIC -> the final name only ever exists as a complete file.
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

      // A cut mid-body still delivers a 200 and a short stream -> trust the LENGTH, not the status.
      if (total != null && total > 0 && received < total) {
        throw const WallpaperApplyException('Download incomplete');
      }

      await part.rename(file.path);
      return file;
    } catch (_) {
      try {
        await sink.close();
      } catch (_) {
        // Already closed by the success path, or dead — either way the .part below is what matters.
      }
      if (await part.exists()) await part.delete();
      rethrow;
    }
  }

  @override
  Future<void> applyStaticWallpaper(File file, ApplyTarget target) async {
    try {
      // Native: setStream plus an OEM lock/both fallback, source normalized first.
      // That normalization is what stops a 4K source OOMing a budget SoC.
      // Returns null on success; throws PlatformException(code, message) on failure.
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
      // The native side copies the MP4 into app-internal storage, persistently.
      // So the running wallpaper service reads a local file forever.
      // It then saves the service config and opens the live-wallpaper chooser.
      // The CHOOSER owns the final home/lock decision -> [target] is not forwarded for live.
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
      // Anything else is the product path, and deliberately the DEFAULT.
      // An unrecognised payload must read as "the chooser is open", never "we applied a still".
      return const LiveApplyResult(LiveApplyOutcome.chooser);
    } on PlatformException catch (e) {
      throw WallpaperApplyException(
        e.message ?? 'Failed to set live wallpaper (${e.code})',
        code: e.code,
      );
    }
  }
}
