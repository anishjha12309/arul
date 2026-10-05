import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../../../core/api/api_client.dart';
import '../domain/status_video.dart';

/// Which gated verb a `/media/signed-url` grant is for; the Worker bumps a different counter per verb.
enum StatusMediaAction {
  share,
  download;

  String get wire => name;
}

class StatusMediaException implements Exception {
  const StatusMediaException(this.message, {this.premiumRequired = false});

  /// DIAGNOSTIC ONLY — English, possibly a raw exception; the UI never shows it.
  final String message;

  /// The Worker refused with 403 `premium_required` -> route to the paywall, never a crash record.
  final bool premiumRequired;

  @override
  String toString() => message;
}

enum StatusSaveOutcome { saved, permissionDenied, failed }

/// [reason] is the native error code on a failure, for `status_save_failed`.
typedef StatusSaveResult = ({StatusSaveOutcome outcome, String? reason});

abstract class StatusMediaService {
  /// The Worker's live entitlement read; a cache must never become a permanent licence.
  Future<String> signedUrl(StatusVideo status, StatusMediaAction action);

  /// Downloads [url] to [outPath]; [onProgress] gets 0.0→1.0.
  Future<File> downloadFile(
    String url,
    String outPath,
    void Function(double) onProgress,
  );

  /// Copies [filePath] into the shared Movies/Arul collection; every call is a fresh entry.
  Future<StatusSaveResult> saveToGallery(String filePath, String displayName);
}

class ApiStatusMediaService implements StatusMediaService {
  ApiStatusMediaService({
    required ApiClient apiClient,
    http.Client? httpClient,
    MethodChannel? channel,
  }) : _api = apiClient,
       _http = httpClient ?? http.Client(),
       _channel = channel ?? const MethodChannel(channelName);

  static const channelName = 'com.hsrutility.arul/status_save';

  final ApiClient _api;
  final http.Client _http;
  final MethodChannel _channel;

  @override
  Future<String> signedUrl(StatusVideo status, StatusMediaAction action) async {
    try {
      final data = await _api.post(
        '/media/signed-url',
        body: {'id': status.id, 'kind': 'status', 'action': action.wire},
      );
      final url = data['url'] as String?;
      if (url == null || url.isEmpty) {
        throw const StatusMediaException('Invalid signed URL response');
      }
      return url;
    } on ApiException catch (e) {
      if (e.isPremiumRequired) {
        throw const StatusMediaException(
          'Premium subscription required',
          premiumRequired: true,
        );
      }
      throw StatusMediaException('Failed to get signed URL (${e.status})');
    }
  }

  @override
  Future<File> downloadFile(
    String url,
    String outPath,
    void Function(double) onProgress,
  ) async {
    final file = File(outPath);
    final part = File('${file.path}.part');

    final response = await _http.send(http.Request('GET', Uri.parse(url)));
    if (response.statusCode != 200) {
      throw StatusMediaException(
        'Download failed (HTTP ${response.statusCode})',
      );
    }
    final total = response.contentLength;
    var received = 0;
    final sink = part.openWrite();
    try {
      await response.stream.listen((chunk) {
        sink.add(chunk);
        received += chunk.length;
        if (total != null && total > 0) onProgress(received / total);
      }, cancelOnError: true).asFuture<void>();
      await sink.flush();
      await sink.close();
      // A cut mid-body still delivers a 200 and a short stream -> trust the LENGTH, not the status.
      if (total != null && total > 0 && received < total) {
        throw const StatusMediaException('Download incomplete');
      }
      return part.rename(file.path);
    } catch (_) {
      try {
        await sink.close();
      } catch (_) {
        // Already closed by the success path.
      }
      if (await part.exists()) await part.delete();
      rethrow;
    }
  }

  @override
  Future<StatusSaveResult> saveToGallery(
    String filePath,
    String displayName,
  ) async {
    try {
      await _channel.invokeMethod<String>('saveVideo', {
        'filePath': filePath,
        'displayName': displayName,
      });
      return (outcome: StatusSaveOutcome.saved, reason: null);
    } on PlatformException catch (e) {
      return e.code == 'permission_denied'
          ? (outcome: StatusSaveOutcome.permissionDenied, reason: e.code)
          : (outcome: StatusSaveOutcome.failed, reason: e.code);
    } on MissingPluginException {
      return (outcome: StatusSaveOutcome.failed, reason: 'no_channel');
    }
  }
}
