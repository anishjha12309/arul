import 'dart:math';

/// The server's video rule: `onVideoRule` in `workers/src/lib/media-verify.ts`. Keep both in step.
abstract final class VideoRule {
  static const widthMultiple = 128;
  static const heightMultiple = 32;
  static const maxShortSide = 1088;
  static const maxLongSide = 1920;

  static bool fits(int width, int height) =>
      width > 0 &&
      height > 0 &&
      width % widthMultiple == 0 &&
      height % heightMultiple == 0 &&
      min(width, height) <= maxShortSide &&
      max(width, height) <= maxLongSide;
}

/// Where a picked video is headed: that target's server rule and the encode that meets it.
enum VideoTarget {
  // Caps are STATUS_VIDEO in media-verify.ts. The cut is 29.8 s, never 30: AAC frame rounding
  // lands a 30 s cut at ~30.1 s and the server refuses it (docs/status-clips.md).
  status(
    maxBytes: 10 * 1024 * 1024,
    maxDurationMs: 30000,
    trimMs: 29800,
    keepsAudio: true,
    videoBitrate: 2000 * 1000,
    retryVideoBitrate: 1500 * 1000,
    audioBitrate: 128 * 1000,
  ),

  // The import pipeline's live recipe (docs/media-conventions.md): cut at 10 s, accepted to 10.5 s,
  // 15 MB ceiling. It is CRF-based; 8 Mbps lands a 10 s cut near 10 MB on a hardware encoder.
  liveWallpaper(
    maxBytes: 15 * 1024 * 1024,
    maxDurationMs: 10500,
    trimMs: 10000,
    keepsAudio: false,
    videoBitrate: 8000 * 1000,
    retryVideoBitrate: 6000 * 1000,
    exactWidth: 1024,
    exactHeight: 1824,
  );

  const VideoTarget({
    required this.maxBytes,
    required this.maxDurationMs,
    required this.trimMs,
    required this.keepsAudio,
    required this.videoBitrate,
    required this.retryVideoBitrate,
    this.audioBitrate,
    this.exactWidth,
    this.exactHeight,
  });

  final int maxBytes;
  final int maxDurationMs;

  /// Where an export cuts a longer clip.
  final int trimMs;

  /// Status must carry its music; a live wallpaper plays muted, so it must carry none.
  final bool keepsAudio;
  final int videoBitrate;

  /// The one retry's bitrate when the first export lands over [maxBytes].
  final int retryVideoBitrate;
  final int? audioBitrate;

  /// Live wallpapers are one canvas; null means the source's own shape on the video rule.
  final int? exactWidth;
  final int? exactHeight;
}

/// Why a video cannot be prepared for its target.
enum VideoPrepFailure {
  /// The clip needs converting and the phone is below Android 12 (API 31).
  unsupportedDevice,

  /// A status needs music and the clip has no audio track.
  noAudio,
  unreadable,

  /// Still over the target's byte cap after the one lower-bitrate retry.
  tooLarge,

  /// Another conversion is running.
  busy,
  cancelled,

  /// The converter failed, or its output missed the plan (size, codec, rotation, audio).
  exportFailed,
}

/// What the native probe read off a video file.
class VideoProbe {
  const VideoProbe({
    required this.width,
    required this.height,
    required this.durationMs,
    required this.hasAudio,
    required this.videoMime,
    required this.bytes,
    this.rotationDegrees = 0,
    this.isMp4 = true,
    this.exportSupported = true,
  });

  /// Reads the native `probe` reply for the file at [path].
  factory VideoProbe.fromChannel(
    Map<String, Object?> map, {
    required String path,
  }) {
    int intOf(String key) => (map[key] as num?)?.toInt() ?? 0;
    return VideoProbe(
      width: intOf('width'),
      height: intOf('height'),
      durationMs: intOf('durationMs'),
      hasAudio: map['hasAudio'] == true,
      videoMime: map['videoMime'] as String?,
      bytes: intOf('bytes'),
      rotationDegrees: intOf('rotation'),
      // The screen's allow-list types an upload by its NAME, and the platform reports a .mov or a
      // .3gp as video/mp4 too, so only an .mp4 name can go up untouched.
      isMp4:
          map['containerMime'] == 'video/mp4' &&
          path.toLowerCase().endsWith('.mp4'),
      exportSupported: map['exportSupported'] == true,
    );
  }

  /// Display size: a 90/270 rotation is already applied.
  final int width;
  final int height;
  final int durationMs;
  final bool hasAudio;

  /// The first video track's codec, e.g. `video/avc`; null when the file has no video.
  final String? videoMime;
  final int bytes;

  /// Non-zero means the stored frame is turned, and the server reads the STORED size.
  final int rotationDegrees;
  final bool isMp4;
  final bool exportSupported;

  bool get isH264 => videoMime == 'video/avc';
}

sealed class VideoPlan {
  const VideoPlan();
}

/// The clip already meets every rule for its target: upload it untouched.
final class PassThroughPlan extends VideoPlan {
  const PassThroughPlan();
}

/// Re-encode to H.264 at exactly [width]x[height]: scaled to cover, the overflow cropped.
final class ExportPlan extends VideoPlan {
  const ExportPlan({
    required this.width,
    required this.height,
    required this.removeAudio,
    required this.videoBitrate,
    this.endMs,
    this.audioBitrate,
  });

  final int width;
  final int height;
  final bool removeAudio;
  final int videoBitrate;

  /// The cut point; null keeps the whole clip.
  final int? endMs;

  /// Null when the audio is removed.
  final int? audioBitrate;

  /// The retry after an export came out [madeBytes] over the cap: the same aspect at a smaller size
  /// on the rule, scaled so the bytes land near [goalBytes]. A quality-mode encoder ignores the
  /// bitrate (MediaTek, A001: 4.3 Mbps asked 2), but its bytes still track the pixel count.
  ExportPlan shrunkToward(
    int madeBytes,
    int goalBytes, {
    required int videoBitrate,
  }) {
    final scale = sqrt(goalBytes / madeBytes).clamp(0.0, 1.0);
    final size = ruleSizeFor(
      max(1, (width * scale).floor()),
      max(1, (height * scale).floor()),
    );
    return ExportPlan(
      width: size.width,
      height: size.height,
      removeAudio: removeAudio,
      videoBitrate: videoBitrate,
      endMs: endMs,
      audioBitrate: audioBitrate,
    );
  }

  ExportPlan withVideoBitrate(int bitrate) => ExportPlan(
    width: width,
    height: height,
    removeAudio: removeAudio,
    videoBitrate: bitrate,
    endMs: endMs,
    audioBitrate: audioBitrate,
  );

  @override
  bool operator ==(Object other) =>
      other is ExportPlan &&
      other.width == width &&
      other.height == height &&
      other.removeAudio == removeAudio &&
      other.videoBitrate == videoBitrate &&
      other.endMs == endMs &&
      other.audioBitrate == audioBitrate;

  @override
  int get hashCode => Object.hash(
    width,
    height,
    removeAudio,
    videoBitrate,
    endMs,
    audioBitrate,
  );

  @override
  String toString() =>
      'ExportPlan(${width}x$height, endMs: $endMs, removeAudio: $removeAudio, '
      'video: $videoBitrate, audio: $audioBitrate)';
}

/// The clip can never meet its target, so nothing is exported.
final class RejectPlan extends VideoPlan {
  const RejectPlan(this.failure);

  final VideoPrepFailure failure;

  @override
  bool operator ==(Object other) =>
      other is RejectPlan && other.failure == failure;

  @override
  int get hashCode => failure.hashCode;

  @override
  String toString() => 'RejectPlan(${failure.name})';
}

VideoPlan planVideo(VideoProbe probe, VideoTarget target) {
  // No duration means no mvhd the server could read either.
  if (probe.videoMime == null ||
      probe.width <= 0 ||
      probe.height <= 0 ||
      probe.durationMs <= 0) {
    return const RejectPlan(VideoPrepFailure.unreadable);
  }
  if (target.keepsAudio && !probe.hasAudio) {
    return const RejectPlan(VideoPrepFailure.noAudio);
  }
  if (_meetsRules(probe, target) &&
      probe.bytes > 0 &&
      probe.bytes <= target.maxBytes) {
    return const PassThroughPlan();
  }
  if (!probe.exportSupported) {
    return const RejectPlan(VideoPrepFailure.unsupportedDevice);
  }
  final size = switch ((target.exactWidth, target.exactHeight)) {
    (final int width, final int height) => (width: width, height: height),
    _ => ruleSizeFor(probe.width, probe.height),
  };
  return ExportPlan(
    width: size.width,
    height: size.height,
    removeAudio: !target.keepsAudio,
    videoBitrate: target.videoBitrate,
    endMs: probe.durationMs > target.trimMs ? target.trimMs : null,
    audioBitrate: target.keepsAudio ? target.audioBitrate : null,
  );
}

enum ExportCheck { ok, tooLarge, offPlan }

/// Judges an export's [output] against the [plan] it was made from.
ExportCheck checkExport(
  VideoProbe output,
  ExportPlan plan,
  VideoTarget target,
) {
  if (output.width != plan.width ||
      output.height != plan.height ||
      output.bytes <= 0 ||
      !_meetsRules(output, target)) {
    return ExportCheck.offPlan;
  }
  return output.bytes > target.maxBytes ? ExportCheck.tooLarge : ExportCheck.ok;
}

/// Every rule of [target] except the byte cap.
bool _meetsRules(VideoProbe probe, VideoTarget target) {
  final sizeOk = switch ((target.exactWidth, target.exactHeight)) {
    (final int width, final int height) =>
      probe.width == width && probe.height == height,
    _ => VideoRule.fits(probe.width, probe.height),
  };
  return sizeOk &&
      probe.isMp4 &&
      probe.isH264 &&
      probe.rotationDegrees == 0 &&
      probe.durationMs > 0 &&
      probe.durationMs <= target.maxDurationMs &&
      probe.hasAudio == target.keepsAudio;
}

const _aspectTolerance = 0.02;

/// The largest size on the video rule within 2% of the source's aspect, never above the source.
({int width, int height}) ruleSizeFor(int sourceWidth, int sourceHeight) {
  final aspect = sourceWidth / sourceHeight;
  final widths = [
    for (
      var w = VideoRule.maxLongSide;
      w >= VideoRule.widthMultiple;
      w -= VideoRule.widthMultiple
    )
      w,
  ];

  for (final w in widths) {
    if (w > sourceWidth) continue;
    final h = _snappedHeight(w, aspect, maxHeight: sourceHeight);
    if (h != null) return (width: w, height: h);
  }
  // A source too small for any such size takes the least upscale; an aspect no size on the rule
  // reaches within 2% takes the closest one, cropped.
  for (final w in widths.reversed) {
    final h = _snappedHeight(w, aspect);
    if (h != null) return (width: w, height: h);
  }

  var best = (width: VideoRule.widthMultiple, height: VideoRule.heightMultiple);
  var bestError = double.infinity;
  for (final w in widths) {
    for (
      var h = VideoRule.heightMultiple;
      h <= VideoRule.maxLongSide;
      h += VideoRule.heightMultiple
    ) {
      if (!VideoRule.fits(w, h)) continue;
      final error = _aspectError(w, h, aspect);
      if (error < bestError ||
          (error == bestError && w * h > best.width * best.height)) {
        best = (width: w, height: h);
        bestError = error;
      }
    }
  }
  return best;
}

/// The on-rule height at width [w] closest to [aspect], within tolerance and [maxHeight].
int? _snappedHeight(int w, double aspect, {int? maxHeight}) {
  final ideal = w / aspect;
  const step = VideoRule.heightMultiple;
  final down = (ideal / step).floor() * step;
  final candidates = [down, down + step]
    ..sort(
      (a, b) =>
          _aspectError(w, a, aspect).compareTo(_aspectError(w, b, aspect)),
    );
  for (final h in candidates) {
    if (h <= 0 || (maxHeight != null && h > maxHeight)) continue;
    if (!VideoRule.fits(w, h)) continue;
    if (_aspectError(w, h, aspect) > _aspectTolerance) continue;
    return h;
  }
  return null;
}

double _aspectError(int width, int height, double aspect) =>
    height <= 0 ? double.infinity : ((width / height) / aspect - 1).abs();
