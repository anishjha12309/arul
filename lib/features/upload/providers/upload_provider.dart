import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../../core/api/api_client.dart';
import '../../auth/providers/auth_providers.dart';
import '../data/api_content_submission_repository.dart';

// ── Constraints (single source of truth for client + server) ─────────────────

/// Single source of truth for upload size/type limits (mirrored server-side).
/// Arul is wallpaper-only — the ringtone limits are NOT ported.
abstract final class UploadConstraints {
  static const int maxStaticWallpaper = 10 * 1024 * 1024; // 10 MB
  static const int maxLiveWallpaper = 50 * 1024 * 1024; // 50 MB

  static const Set<String> staticWallpaperTypes = {
    'image/jpeg',
    'image/png',
    'image/webp',
  };
  static const Set<String> liveWallpaperTypes = {'video/mp4'};

  static int maxBytes(String wallpaperType) =>
      wallpaperType == 'live' ? maxLiveWallpaper : maxStaticWallpaper;

  static Set<String> allowedTypes(String wallpaperType) =>
      wallpaperType == 'live' ? liveWallpaperTypes : staticWallpaperTypes;

  static String typeLabel(String wallpaperType) =>
      wallpaperType == 'live' ? 'MP4 video' : 'JPEG, PNG or WebP image';

  static String maxLabel(String wallpaperType) {
    final mb = maxBytes(wallpaperType) ~/ (1024 * 1024);
    return '${mb}MB';
  }

  /// Best-effort MIME type derived from a filename extension. Unsupported types
  /// resolve to a value the allow-list ([allowedTypes]) rejects with a clear error.
  static String mimeFromName(String name) {
    final ext = name.split('.').last.toLowerCase();
    return switch (ext) {
      'jpg' || 'jpeg' => 'image/jpeg',
      'png' => 'image/png',
      'webp' => 'image/webp',
      'gif' => 'image/gif',
      'mp4' => 'video/mp4',
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
  /// Arul: [kind] is always `'wallpaper'` and [category] is REQUIRED by the
  /// form (approval copies the file to `wallpapers/<category>/…`).
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

    // Derive userId from current auth state.
    final authState = ref.read(authStateStreamProvider).asData?.value;
    final userId = authState?.userId;
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
