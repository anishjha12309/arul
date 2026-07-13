import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Native first-frame stills for live wallpapers — the grid's FALLBACK when a
/// pre-generated `thumbs/` object is missing (e.g. a wallpaper published before
/// the thumbnail job ran).
///
/// The MP4s are `+faststart`, so the native MediaMetadataRetriever pulls the
/// header plus the bytes around 0.5s — tens of KB, not the 4 MB clip — and caches
/// the decoded frame on disk forever. A grid can therefore show a live item
/// without holding a video decoder for it, which is the whole point: a budget SoC
/// has only a handful of hardware decoders and a player-per-tile grid would fall
/// back to software decode and stutter.
class VideoThumbnailService {
  VideoThumbnailService({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_channelName);

  static const _channelName = 'com.hsrapps.arul/video_thumb';

  final MethodChannel _channel;

  /// In-flight and completed lookups, so a fling that rebuilds the same tile
  /// several times issues ONE native call, not one per build.
  final Map<String, Future<File?>> _inFlight = {};

  Future<File?> thumbnail(String videoUrl) {
    return _inFlight.putIfAbsent(videoUrl, () async {
      try {
        final path = await _channel.invokeMethod<String>('thumbnail', {
          'url': videoUrl,
        });
        if (path == null) return null;
        final file = File(path);
        return await file.exists() ? file : null;
      } on PlatformException catch (e) {
        // Expected on a dead link or an unreadable clip. The tile shows its
        // skeleton; it must not throw into the grid's build.
        debugPrint('video thumbnail failed for $videoUrl: ${e.message}');
        // Drop the memo so a later scroll can retry (e.g. once connectivity is
        // back) instead of caching the failure for the whole session. The
        // removed value is this very future — discarding it is the point.
        unawaited(_inFlight.remove(videoUrl) ?? Future<File?>.value());
        return null;
      } on MissingPluginException {
        return null; // tests / non-Android host
      }
    });
  }
}
