import 'package:flutter/services.dart';

/// What the person picked: a plain file the native side already copied into the app cache.
class PickedMedia {
  const PickedMedia({required this.path, required this.name});

  /// Absolute path of the cached copy — readable as a `File`, gone at the next pick.
  final String path;

  /// The provider's display name, extension included; `UploadConstraints.mimeFromName` reads it.
  final String name;
}

/// Which system picker to open.
enum MediaPickKind {
  /// The Android Photo Picker: images and video, never audio.
  visual,

  /// The documents picker opened at the audio root: what a ringtone submission needs.
  audio,
}

/// Asks the native side to open the system picker for [MediaPickKind] and hand back a copy.
///
/// Replaces the file_picker plugin: the pickers need no permission, and the plugin's Android side
/// carried an Apache Tika MIME sniffer the app never used (the extension allow-list decides).
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
        'kind': kind == MediaPickKind.audio ? 'audio' : 'visual',
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
}
