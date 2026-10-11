import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../../core/api/api_client.dart';
import '../../auth/providers/auth_providers.dart';
import '../data/api_content_submission_repository.dart';
import '../data/video_prep_service.dart';

/// What a submission is. [name] is the wire value the Worker and the CMS key on.
enum UploadKind { wallpaper, ringtone, status }

/// Single source of truth for upload size and type limits.
/// Mirrored in `workers/src/lib/media-constraints.ts` and again in the CMS — keep all three in step.
///
/// Keyed on `kind`; `wallpaperType` only narrows the wallpaper branch and is ignored otherwise.
/// A video is checked AFTER the phone prepared it ([VideoPrepService]), so these are the MP4's limits.
abstract final class UploadConstraints {
  static const int maxStaticWallpaper = 10 * 1024 * 1024;
  static const int maxLiveWallpaper = 50 * 1024 * 1024;
  static const int maxRingtone = 15 * 1024 * 1024;

  /// The Worker's status QC cap (`STATUS_VIDEO.maxBytes`), stricter than a live wallpaper's.
  static const int maxStatus = 10 * 1024 * 1024;

  static const Set<String> staticWallpaperTypes = {
    'image/jpeg',
    'image/png',
    'image/webp',
  };
  static const Set<String> liveWallpaperTypes = {'video/mp4'};
  static const Set<String> statusTypes = {'video/mp4'};
  static const Set<String> ringtoneTypes = {
    'audio/mpeg',
    'audio/aac',
    'audio/mp4',
    'audio/x-m4a',
  };

  static int maxBytes(String kind, String wallpaperType) {
    if (kind == 'ringtone') return maxRingtone;
    if (kind == 'status') return maxStatus;
    return wallpaperType == 'live' ? maxLiveWallpaper : maxStaticWallpaper;
  }

  static Set<String> allowedTypes(String kind, String wallpaperType) {
    if (kind == 'ringtone') return ringtoneTypes;
    if (kind == 'status') return statusTypes;
    return wallpaperType == 'live' ? liveWallpaperTypes : staticWallpaperTypes;
  }

  static String maxLabel(String kind, String wallpaperType) {
    final mb = maxBytes(kind, wallpaperType) ~/ (1024 * 1024);
    return '${mb}MB';
  }

  /// Best-effort MIME from a filename extension.
  /// An unsupported type resolves to a value [allowedTypes] rejects with a clear error.
  /// `m4a` maps to `audio/mp4` — the server allows both, and byte-level QC re-derives the container.
  /// `ogg`/`wav`/`flac` are NAMED so picking one gets the authored rejection, not octet-stream.
  static String mimeFromName(String name) {
    final ext = name.split('.').last.toLowerCase();
    return switch (ext) {
      'jpg' || 'jpeg' => 'image/jpeg',
      'png' => 'image/png',
      'webp' => 'image/webp',
      'gif' => 'image/gif',
      'mp4' => 'video/mp4',
      // Videos the phone converts to MP4 before upload -> named so a pick reads as a video.
      'mov' => 'video/quicktime',
      '3gp' => 'video/3gpp',
      'mkv' => 'video/x-matroska',
      'webm' => 'video/webm',
      'mp3' => 'audio/mpeg',
      'aac' => 'audio/aac',
      'm4a' => 'audio/mp4',
      'ogg' => 'audio/ogg',
      'wav' => 'audio/wav',
      'flac' => 'audio/flac',
      _ => 'application/octet-stream',
    };
  }
}

sealed class UploadState {
  const UploadState();
}

/// Which step of the upload is in flight, mapped to a localized label by the UI.
/// An ENUM, not text — a provider has no `BuildContext` to localize against.
enum UploadStage { uploading, saving }

final class UploadIdle extends UploadState {
  const UploadIdle();
}

final class UploadLoading extends UploadState {
  const UploadLoading({required this.stage});
  final UploadStage stage;
}

final class UploadSuccess extends UploadState {
  const UploadSuccess();
}

final class UploadError extends UploadState {
  const UploadError({required this.message, this.code});
  final String message;

  /// The Worker's error code (`too_large`, `bad_dimensions`, `too_many_pending`…), null when the
  /// failure never reached it. The screen words its toast from this, never from [message].
  final String? code;
}

class UploadNotifier extends Notifier<UploadState> {
  @override
  UploadState build() => const UploadIdle();

  /// Three steps: presigned R2 PUT URL from the Worker, PUT the bytes to R2, record for moderation.
  ///
  /// [category] is REQUIRED for both kinds — approval copies into `<kind>s/<category>/…`.
  /// The two kinds do NOT share a category list: ringtones drop `temples`.
  Future<void> submit({
    required String kind,
    required String filePath,
    required String fileName,
    required String mimeType,
    required int fileSize,
    String? title,
    String? category,
  }) async {
    final apiClient = ref.read(apiClientProvider);

    // The stream provider is broadcast and does NOT replay -> `.asData` is null with no subscriber.
    // A cold start straight to upload would then bounce a signed-in user with "Not signed in".
    // So derive userId from the auth service's SYNCHRONOUS state.
    final authState = ref.read(authServiceProvider).currentState;
    final userId = authState.userId;
    if (userId == null) {
      state = const UploadError(message: 'Not signed in');
      return;
    }

    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final fileKey = 'user/$userId/submissions/${timestamp}_$fileName';

    try {
      state = const UploadLoading(stage: UploadStage.uploading);
      final urlData = await apiClient.post(
        '/media/upload-url',
        body: {
          'key': fileKey,
          'contentType': mimeType,
          'size': fileSize,
          'kind': kind,
        },
      );

      final uploadUrl = urlData['uploadUrl'] as String?;
      if (uploadUrl == null) {
        state = const UploadError(message: 'Upload URL not received');
        return;
      }

      final fileBytes = await File(filePath).readAsBytes();
      final putResp = await http.put(
        Uri.parse(uploadUrl),
        headers: {'Content-Type': mimeType},
        body: fileBytes,
      );

      if (putResp.statusCode != 200) {
        state = UploadError(
          message: 'File upload failed (${putResp.statusCode})',
        );
        return;
      }

      state = const UploadLoading(stage: UploadStage.saving);
      final repo = ApiContentSubmissionRepository(apiClient: apiClient);
      final trimmedTitle = title?.trim();
      await repo.createSubmission(
        userId: userId,
        kind: kind,
        fileKey: fileKey,
        title: (trimmedTitle?.isNotEmpty == true) ? trimmedTitle : null,
        category: category,
      );

      state = const UploadSuccess();
    } on ApiException catch (e) {
      state = UploadError(message: e.message, code: e.code);
    } catch (e) {
      state = UploadError(message: e.toString());
    }
  }

  void reset() => state = const UploadIdle();
}

final uploadProvider = NotifierProvider<UploadNotifier, UploadState>(
  UploadNotifier.new,
);

final videoPrepServiceProvider = Provider<VideoPrepService>(
  (ref) => VideoPrepService(),
);
