import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../../../core/api/api_client.dart';

/// Android RingtoneManager tone slots — Arul's UI only ever offers [RingtoneTarget.ringtone].
/// The full enum is kept so the native channel contract stays identical to the reference's.
enum RingtoneTarget { ringtone, notification, alarm }

extension RingtoneTargetAndroid on RingtoneTarget {
  /// Integer constants matching Android's RingtoneManager TYPE_* values.
  int get androidType => switch (this) {
    RingtoneTarget.ringtone => 1,
    RingtoneTarget.notification => 2,
    RingtoneTarget.alarm => 4,
  };
}

class RingtoneSetException implements Exception {
  const RingtoneSetException(this.message, {this.premiumRequired = false});
  final String message;

  /// The Worker refused with 403 `premium_required` → route to the paywall.
  ///
  /// Entitlement is read live from Neon -> a lapse or refund mid-session lands here.
  /// An ordinary business condition: no crash record, and a toast would be a dead end.
  final bool premiumRequired;

  @override
  String toString() => message;
}

abstract interface class RingtoneSetService {
  /// Calls the Worker `/media/signed-url` with the ringtone [id].
  /// The server runs the LIVE entitlement check and resolves the key to a short-lived signed URL.
  Future<String> fetchSignedUrl(String id);

  /// Streams [url] to a temp file named [filename].
  /// [onProgress] receives values 0.0–1.0 as bytes arrive.
  Future<File> downloadFile(
    String url,
    String filename,
    void Function(double) onProgress,
  );

  /// Returns true if the app holds `WRITE_SETTINGS` special permission.
  Future<bool> canWriteSettings();

  /// Launches Android's `ACTION_MANAGE_WRITE_SETTINGS` intent so the user can
  /// grant the special permission.
  Future<void> openWriteSettings();

  /// Registers [file] in MediaStore and sets it as the device [target] tone.
  ///
  /// [title] is the name shown in the system sound picker, sanitized natively.
  /// [mime] is the real content type registered with MediaStore.
  /// Both come from the catalog row — the file is named by ringtone id, which the user must not see.
  /// Throws [RingtoneSetException] on failure.
  Future<void> setRingtone(
    File file,
    RingtoneTarget target, {
    required String title,
    required String mime,
  });
}

class AndroidRingtoneSetService implements RingtoneSetService {
  AndroidRingtoneSetService({
    required ApiClient apiClient,
    http.Client? httpClient,
  }) : _api = apiClient,
       _http = httpClient ?? http.Client();

  final ApiClient _api;
  final http.Client _http;

  static const _channel = MethodChannel('com.hsrutility.arul/ringtone_set');

  @override
  Future<String> fetchSignedUrl(String id) async {
    try {
      final data = await _api.post(
        '/media/signed-url',
        body: {'id': id, 'kind': 'ringtone'},
      );
      final url = data['url'] as String?;
      if (url == null || url.isEmpty) {
        throw const RingtoneSetException('Invalid signed URL response');
      }
      return url;
    } on ApiException catch (e) {
      if (e.isPremiumRequired) {
        // The client gate already ran -> reaching here means its snapshot was stale.
        throw const RingtoneSetException(
          'Premium subscription required',
          premiumRequired: true,
        );
      }
      throw RingtoneSetException('Failed to get signed URL (${e.status})');
    }
  }

  @override
  Future<File> downloadFile(
    String url,
    String filename,
    void Function(double) onProgress,
  ) async {
    final request = http.Request('GET', Uri.parse(url));
    final response = await _http.send(request);

    if (response.statusCode != 200) {
      throw RingtoneSetException(
        'Download failed (HTTP ${response.statusCode})',
      );
    }

    final total = response.contentLength;
    int received = 0;

    final tmpDir = await getTemporaryDirectory();
    final file = File('${tmpDir.path}/$filename');
    final sink = file.openWrite();

    try {
      await response.stream.listen((List<int> chunk) {
        sink.add(chunk);
        received += chunk.length;
        if (total != null && total > 0) {
          onProgress(received / total);
        }
      }, cancelOnError: true).asFuture<void>();
    } finally {
      await sink.flush();
      await sink.close();
    }

    return file;
  }

  @override
  Future<bool> canWriteSettings() async {
    final result = await _channel.invokeMethod<bool>('canWriteSettings');
    return result ?? false;
  }

  @override
  Future<void> openWriteSettings() =>
      _channel.invokeMethod<void>('openWriteSettings');

  @override
  Future<void> setRingtone(
    File file,
    RingtoneTarget target, {
    required String title,
    required String mime,
  }) async {
    try {
      await _channel.invokeMethod<void>('setRingtone', {
        'filePath': file.path,
        'type': target.androidType,
        'title': title,
        'mime': mime,
      });
    } on PlatformException catch (e) {
      // e.message is raw platform text — log it, but surface only the authored message.
      debugPrint('[RingtoneSet] ${e.code}: ${e.message}');
      throw RingtoneSetException(e.message ?? 'Failed to set ringtone');
    }
  }
}
