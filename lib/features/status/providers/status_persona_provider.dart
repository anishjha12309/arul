import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/providers/shared_preferences_provider.dart';
import '../../auth/providers/auth_providers.dart';
import '../../upload/data/media_pick_service.dart';
import '../../wallpapers/data/share_watermark_service.dart';

/// The user's own photo and name on statuses, and whether each is shown. The photo lives only on
/// this phone (owner); the name is the account's display name.
@immutable
class StatusPersona {
  const StatusPersona({
    this.photo,
    this.showPhoto = true,
    this.showName = true,
  });

  /// The square photo, decoded once and painted by every card and every export.
  final ui.Image? photo;
  final bool showPhoto;
  final bool showName;

  ui.Image? get shownPhoto => showPhoto ? photo : null;
}

/// App-support, not the pick cache: `upload_picks` is wiped on every engine start.
final statusPersonaDirProvider = FutureProvider<Directory>(
  (_) => getApplicationSupportDirectory(),
);

final mediaPickServiceProvider = Provider<MediaPickService>(
  (_) => const MediaPickService(),
);

/// Whether this phone can burn the photo and name into a clip: the Media3 export needs API 31
/// (docs/known-issues.md). Below it the feature explains itself and clips go out as before.
final statusPersonaSupportedProvider = FutureProvider<bool>((ref) async {
  final support = await ref
      .read(shareWatermarkServiceProvider)
      .videoWatermarkSupport();
  return support.supported;
});

/// The name painted on statuses: the account's, trimmed; null when there is none to show.
final statusPersonaNameProvider = Provider<String?>((ref) {
  // The auth stream does not replay -> watch it for changes, read the service for the value.
  ref.watch(authStateStreamProvider);
  final name = ref.read(authServiceProvider).currentState.displayName?.trim();
  return (name == null || name.isEmpty) ? null : name;
});

/// Whether cards carry the name band under the clip: the export works on this phone, the name switch
/// is on, and there is a name. The card's shape and the painter both read this one answer.
final statusNameBandProvider = Provider<bool>((ref) {
  if (ref.watch(statusPersonaSupportedProvider).value != true) return false;
  final persona = ref.watch(statusPersonaProvider).value;
  return persona != null &&
      persona.showName &&
      ref.watch(statusPersonaNameProvider) != null;
});

final statusPersonaProvider =
    AsyncNotifierProvider<StatusPersonaNotifier, StatusPersona>(
      StatusPersonaNotifier.new,
    );

class StatusPersonaNotifier extends AsyncNotifier<StatusPersona> {
  static const showPhotoKey = 'arul_status_show_photo';
  static const showNameKey = 'arul_status_show_name';
  static const photoFile = 'status_photo.jpg';

  /// Side of the stored photo: the largest slot is ~63% of a 1024-wide clip, so 640 never upscales.
  static const photoSide = 640;

  @override
  Future<StatusPersona> build() async {
    final prefs = ref.read(sharedPreferencesProvider);
    final photo = await _decode(await _photoFile());
    return StatusPersona(
      photo: photo,
      showPhoto: prefs.getBool(showPhotoKey) ?? true,
      showName: prefs.getBool(showNameKey) ?? true,
    );
  }

  Future<File> _photoFile() async =>
      File('${(await ref.read(statusPersonaDirProvider.future)).path}/$photoFile');

  static Future<ui.Image?> _decode(File file) async {
    try {
      if (!await file.exists()) return null;
      final codec = await ui.instantiateImageCodec(await file.readAsBytes());
      final frame = await codec.getNextFrame();
      codec.dispose();
      return frame.image;
    } catch (_) {
      // A torn or foreign file is the same as no photo: the user picks again.
      return null;
    }
  }

  /// Opens the photo picker and stores a centre-cropped square. False when the user backed out.
  Future<bool> pickPhoto() async {
    final picker = ref.read(mediaPickServiceProvider);
    final picked = await picker.pick(MediaPickKind.image);
    if (picked == null || !ref.mounted) return false;
    final target = await _photoFile();
    final staging = File('${target.path}.part');
    try {
      await picker.squarePhoto(
        inputPath: picked.path,
        outputPath: staging.path,
        side: photoSide,
      );
      await staging.rename(target.path);
    } finally {
      // The pick's cached copy is ours to delete once it is cropped.
      unawaited(_deleteQuietly(File(picked.path)));
    }
    final photo = await _decode(target);
    if (!ref.mounted) return false;
    if (photo == null) throw StateError('cropped photo did not decode');
    _replace((s) => StatusPersona(
      photo: photo,
      showPhoto: true,
      showName: s.showName,
    ));
    await ref.read(sharedPreferencesProvider).setBool(showPhotoKey, true);
    return true;
  }

  Future<void> removePhoto() async {
    await _deleteQuietly(await _photoFile());
    if (!ref.mounted) return;
    _replace((s) => StatusPersona(showPhoto: s.showPhoto, showName: s.showName));
  }

  Future<void> setShowPhoto(bool show) async {
    _replace((s) => StatusPersona(photo: s.photo, showPhoto: show, showName: s.showName));
    await ref.read(sharedPreferencesProvider).setBool(showPhotoKey, show);
  }

  Future<void> setShowName(bool show) async {
    _replace((s) => StatusPersona(photo: s.photo, showPhoto: s.showPhoto, showName: show));
    await ref.read(sharedPreferencesProvider).setBool(showNameKey, show);
  }

  void _replace(StatusPersona Function(StatusPersona) next) {
    // A replaced photo is left to the GC: a card may still be painting it this frame.
    state = AsyncData(next(state.value ?? const StatusPersona()));
  }

  static Future<void> _deleteQuietly(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {
      // Already gone or locked by the OS -> nothing left to protect.
    }
  }
}
