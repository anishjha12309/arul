import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../../core/api/api_client.dart';
import '../../auth/providers/auth_providers.dart';
import '../data/api_content_submission_repository.dart';

// ── Constraints (single source of truth for client + server) ─────────────────

/// Single source of truth for upload size/type limits, mirrored server-side in
/// `workers/src/lib/media-constraints.ts` (and a third copy in the CMS) — keep
/// all three in step.
///
/// The limits are keyed on `kind` ('wallpaper' | 'ringtone'); `wallpaperType`
/// ('static' | 'live') only narrows the wallpaper branch and is ignored for a
/// ringtone.
abstract final class UploadConstraints {
  static const int maxStaticWallpaper = 10 * 1024 * 1024; // 10 MB
  static const int maxLiveWallpaper = 50 * 1024 * 1024; // 50 MB
  static const int maxRingtone = 15 * 1024 * 1024; // 15 MB

  static const Set<String> staticWallpaperTypes = {
    'image/jpeg',
    'image/png',
    'image/webp',
  };
  static const Set<String> liveWallpaperTypes = {'video/mp4'};
  static const Set<String> ringtoneTypes = {
    'audio/mpeg',
    'audio/aac',
    'audio/mp4',
    'audio/x-m4a',
  };

  static int maxBytes(String kind, String wallpaperType) {
    if (kind == 'ringtone') return maxRingtone;
    return wallpaperType == 'live' ? maxLiveWallpaper : maxStaticWallpaper;
  }

  static Set<String> allowedTypes(String kind, String wallpaperType) {
    if (kind == 'ringtone') return ringtoneTypes;
    return wallpaperType == 'live' ? liveWallpaperTypes : staticWallpaperTypes;
  }

  static String maxLabel(String kind, String wallpaperType) {
    final mb = maxBytes(kind, wallpaperType) ~/ (1024 * 1024);
    return '${mb}MB';
  }

  /// Best-effort MIME type derived from a filename extension. Unsupported types
  /// resolve to a value the allow-list ([allowedTypes]) rejects with a clear error.
  ///
  /// `m4a` maps to `audio/mp4` — the server's allow-list carries BOTH that and
  /// `audio/x-m4a`, but the presigned PUT stores whatever is sent here, and the
  /// byte-level QC re-derives the real container from the bytes either way.
  /// `ogg`/`wav`/`flac` are named so a user who picks one gets the authored
  /// "choose an MP3/AAC/M4A" rejection instead of the generic octet-stream path.
  static String mimeFromName(String name) {
    final ext = name.split('.').last.toLowerCase();
    return switch (ext) {
      'jpg' || 'jpeg' => 'image/jpeg',
      'png' => 'image/png',
      'webp' => 'image/webp',
      'gif' => 'image/gif',
      'mp4' => 'video/mp4',
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

// ── State ─────────────────────────────────────────────────────────────────────

/// Upload flow state: idle → loading (per stage) → success | error.
sealed class UploadState {
  const UploadState();
}

/// Which step of the upload is in flight. The UI maps this to a localized
/// label (the stage is an enum, not text, because providers have no
/// `BuildContext` to localize against).
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
  const UploadError({required this.message});
  final String message;
}

// ── Notifier ─────────────────────────────────────────────────────────────────

/// Drives the content upload flow and exposes its [UploadState].
class UploadNotifier extends Notifier<UploadState> {
  @override
  UploadState build() => const UploadIdle();

  /// Three-step upload: fetch a presigned R2 PUT URL from the Worker, PUT the
  /// file bytes straight to R2, then record the submission for moderation.
  /// [kind] is `'wallpaper'` or `'ringtone'`, and [category] is REQUIRED by the
  /// form for BOTH — approval copies the file to `wallpapers/<category>/…` or
  /// `ringtones/<category>/…`, and `ringtones.category` is NOT NULL. The two
  /// kinds do NOT share a category list (ringtones drop `temples`, add `others`).
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

    // Derive userId from the auth service's synchronous state — the stream
    // provider is broadcast and does NOT replay, so its .asData is null when
    // nothing was subscribed at emission time (e.g. a cold start straight to
    // upload), which would bounce a signed-in user with "Not signed in".
    final authState = ref.read(authServiceProvider).currentState;
    final userId = authState.userId;
    if (userId == null) {
      state = const UploadError(message: 'Not signed in');
      return;
    }

    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final fileKey = 'user/$userId/submissions/${timestamp}_$fileName';

    try {
      // ── 1. Get presigned PUT URL from Worker ───────────────────────────────
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

      // ── 2. PUT file bytes directly to R2 ──────────────────────────────────
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

      // ── 3. Record submission via Worker ────────────────────────────────────
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
      state = UploadError(message: e.message);
    } catch (e) {
      state = UploadError(message: e.toString());
    }
  }

  void reset() => state = const UploadIdle();
}

final uploadProvider = NotifierProvider<UploadNotifier, UploadState>(
  UploadNotifier.new,
);
