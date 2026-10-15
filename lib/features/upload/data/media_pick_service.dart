import 'package:flutter/services.dart';

/// What the person picked: a plain file the native side already copied into the app cache.
class PickedMedia {
  const PickedMedia({required this.path, required this.name});

  /// Absolute path of the cached copy — readable as a `File`, gone at the next pick.
  final String path;

  /// The provider's display name, extension included; `UploadConstraints.mimeFromName` reads it.
  final String name;
}

enum MediaPickKind {
  /// The Android Photo Picker: images and video, never audio.
  visual,

  /// The Photo Picker filtered to video: a status clip or a live wallpaper.
  video,

  /// The documents picker opened at the audio root: what a ringtone submission needs.
  audio,

  /// The Photo Picker filtered to images: the user's own photo for statuses.
  image,
}

/// Asks the native side to open the system picker for [MediaPickKind] and hand back a copy.
/// Resolves to null when the person dismissed the picker, or when there is no native side to ask.
/// Throws only for a pick that STARTED and then failed (no picker on the phone, an unreadable
/// provider) — the caller shows the reason rather than a silent nothing.
class MediaPickService {
  const MediaPickService({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  static const channelName = 'com.hsrutility.arul/media_pick';

  final MethodChannel _channel;

  Future<PickedMedia?> pick(MediaPickKind kind) async {
    final Map<Object?, Object?>? answer;
    try {
      answer = await _channel.invokeMethod<Map<Object?, Object?>>('pick', {
        'kind': switch (kind) {
          MediaPickKind.visual => 'visual',
          MediaPickKind.video => 'video',
          MediaPickKind.audio => 'audio',
          MediaPickKind.image => 'image',
        },
      });
    } on MissingPluginException {
      // No native side (tests, a future platform) -> the same as a dismissed picker.
      return null;
    }
    final path = answer?['path'] as String?;
    final name = answer?['name'] as String?;
    if (path == null || name == null) return null;
    return PickedMedia(path: path, name: name);
  }

  /// Decodes [inputPath] (HEIC and EXIF rotation included), centre-crops it to a square and writes
  /// a [side]-pixel JPEG to [outputPath]. Throws when the native side cannot.
  Future<void> squarePhoto({
    required String inputPath,
    required String outputPath,
    required int side,
  }) async {
    await _channel.invokeMethod<void>('squarePhoto', {
      'inputPath': inputPath,
      'outputPath': outputPath,
      'side': side,
    });
  }
}
