import 'dart:io';

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
  const WallpaperApplyException(this.message);
  final String message;

  @override
  String toString() => message;
}

// ─── Interface ───────────────────────────────────────────────────────────────

abstract class WallpaperApplyService {
  /// The PUBLIC CDN URL for [w]'s media. Used as the prefetch-cache lookup key
  /// (the feed prefetcher caches by this URL) — NOT necessarily the URL the
  /// gated download uses; see [downloadUrl].
  Future<String> resolveUrl(Wallpaper w);

  /// The URL the gated apply/share download actually fetches. With a backend
  /// this is the Worker's `POST /media/signed-url` — the REAL premium gate: a
  /// live entitlement read returning a short-lived signed URL. Without one
  /// (pre-Phase-0) it degrades to the public CDN object.
  Future<String> downloadUrl(Wallpaper w);

  /// Downloads [url] to a temp file named [filename]. [onProgress] gets 0.0→1.0.
  Future<File> downloadFile(
    String url,
    String filename,
    void Function(double) onProgress,
  );

  /// Applies [file] as a static wallpaper to [target] screen(s).
  Future<void> applyStaticWallpaper(File file, ApplyTarget target);

  /// Sets [file] (an MP4) as a live wallpaper. When our service is ALREADY the
  /// active system wallpaper, the native side swaps the running engine's video
  /// in place — instant, no chooser. Otherwise it persists the video and opens
  /// the system live-wallpaper chooser, where the user makes the final tap.
  Future<void> applyLiveWallpaper(File file, ApplyTarget target);

  /// True when our own live-wallpaper service is the device's ACTIVE wallpaper
  /// on any surface — i.e. the next [applyLiveWallpaper] is an instant in-place
  /// swap with no OS chooser. False on any platform error (callers then assume
  /// the chooser path, which is the safe assumption).
  Future<bool> isOwnLiveWallpaperActive();
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

  static const _channelName = 'com.hsrapps.arul/wallpaper';

  /// Present only when the Worker exists — drives the signed-url gate.
  final ApiClient? _api;

  final http.Client _http;

  /// Our own channel (com.hsrapps.arul.wallpaper.WallpaperApplyChannel) — there
  /// is no third-party wallpaper plugin in this app.
  final MethodChannel _channel;

  @override
  Future<String> resolveUrl(Wallpaper w) async => w.url(AppConfig.cdnBaseUrl);

  @override
  Future<String> downloadUrl(Wallpaper w) async {
    final api = _api;
    if (api == null || !AppConfig.hasBackend) {
      // Pre-backend stub: keys are public by design (soft gate).
      return w.url(AppConfig.cdnBaseUrl);
    }
    try {
      final data = await api.post(
        '/media/signed-url',
        body: {'id': w.id, 'kind': 'wallpaper'},
      );
      final url = data['url'] as String?;
      if (url == null || url.isEmpty) {
        throw const WallpaperApplyException('Invalid signed URL response');
      }
      return url;
    } on ApiException catch (e) {
      if (e.isPremiumRequired) {
        throw const WallpaperApplyException('Premium subscription required');
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
      );
    }
  }

  @override
  Future<void> applyLiveWallpaper(File file, ApplyTarget target) async {
    try {
      // Native copies the MP4 into app-internal storage (persistent — the running
      // wallpaper service reads that local file forever), saves the service
      // config, then swaps in place or opens the live-wallpaper chooser. The
      // chooser owns the final home/lock decision, so [target] is not forwarded
      // for live; it stays in the signature for symmetry with static.
      await _channel.invokeMethod<void>('setVideoWallpaper', {
        'filePath': file.path,
        'enableAudio': false,
        'loop': true,
      });
    } on PlatformException catch (e) {
      throw WallpaperApplyException(
        e.message ?? 'Failed to set live wallpaper (${e.code})',
      );
    }
  }

  @override
  Future<bool> isOwnLiveWallpaperActive() async {
    try {
      return await _channel.invokeMethod<bool>('isLiveWallpaperActive') ??
          false;
    } on PlatformException {
      return false; // conservative: assume the chooser path
    } on MissingPluginException {
      return false; // tests / unsupported host
    }
  }
}
