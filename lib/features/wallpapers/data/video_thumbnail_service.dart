import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Native first-frame stills for live wallpapers — the FALLBACK when a `thumbs/` object is missing.
///
/// The MP4s are `+faststart` -> the retriever pulls the header plus ~0.5s, tens of KB, not 4 MB.
/// The decoded frame is then cached on disk forever.
/// So a grid shows a live item WITHOUT holding a video decoder for it.
/// A budget SoC has a handful of hardware decoders; a player per tile falls back to software.
class VideoThumbnailService {
  VideoThumbnailService({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_channelName);

  static const _channelName = 'com.hsrutility.arul/video_thumb';

  final MethodChannel _channel;

  /// In-flight and completed lookups -> a fling that rebuilds a tile issues ONE native call.
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
        // Expected on a dead link or an unreadable clip -> the tile shows its skeleton.
        // It must never throw into the grid's build.
        debugPrint('video thumbnail failed for $videoUrl: ${e.message}');
        // Drop the memo -> a later scroll retries instead of caching the failure all session.
        // The removed value is this very future — discarding it is the point.
        unawaited(_inFlight.remove(videoUrl) ?? Future<File?>.value());
        return null;
      } on MissingPluginException {
        return null; // tests / non-Android host
      }
    });
  }
}
