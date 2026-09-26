import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/api/api_client.dart';

/// Android RingtoneManager tone slots — Arul's UI only ever offers [RingtoneTarget.ringtone].
/// The full enum is kept so the native channel contract stays identical to the reference's.
enum RingtoneTarget { ringtone, notification, alarm }

extension RingtoneTargetAndroid on RingtoneTarget {
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

/// Where one tone lives on the device — its MediaStore URI and the file name MediaStore filed it
/// under.
///
/// The set's receipt and a later read of the system row produce the SAME shape from the same native
/// query, so the two are directly comparable. The URI is the identity; the name is the fallback axis,
/// because a media rescan re-keys the row and strands the URI while the file name survives it.
class RingtoneRef {
  const RingtoneRef({required this.uri, this.displayName});

  final String uri;

  /// MediaStore's `DISPLAY_NAME` — the catalog title plus the extension, already uniquified by
  /// MediaStore if it had to be. Null when the provider refused the column.
  final String? displayName;

  static RingtoneRef? fromChannel(Map<Object?, Object?>? map) {
    final uri = map?['uri'] as String?;
    if (uri == null || uri.isEmpty) return null;
    final name = map?['displayName'] as String?;
    return RingtoneRef(
      uri: uri,
      displayName: (name == null || name.isEmpty) ? null : name,
    );
  }

  static RingtoneRef? fromJson(Object? json) =>
      json is Map<String, dynamic> ? fromChannel(json) : null;

  Map<String, Object?> toJson() => {'uri': uri, 'displayName': displayName};
}

/// The tones Arul itself installed, keyed by ringtone id.
///
/// NOT the answer to "which tone is current" — the system row is, and this is only what that row is
/// compared AGAINST. A tone the user changed outside Arul matches nothing stored here, which is
/// exactly how the badge takes itself off.
class RingtoneRefStore {
  const RingtoneRefStore(this._prefs);

  final SharedPreferences _prefs;

  static const prefsKey = 'arul_ringtone_uris';

  /// The catalog is tens of tracks, so this cap is never reached in practice — it only stops a long
  /// run of sets growing the pref without bound. The oldest write goes first, and the tone that is
  /// current is by definition among the most recent.
  static const _maxEntries = 32;

  Map<String, RingtoneRef> read() {
    final raw = _prefs.getString(prefsKey);
    if (raw == null || raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return const {};
      final out = <String, RingtoneRef>{};
      for (final entry in decoded.entries) {
        final ref = RingtoneRef.fromJson(entry.value);
        if (ref != null) out[entry.key] = ref;
      }
      return out;
    } catch (_) {
      return const {};
    }
  }

  Future<void> record(String ringtoneId, RingtoneRef ref) async {
    final next = Map<String, RingtoneRef>.from(read())..remove(ringtoneId);
    next[ringtoneId] = ref;
    while (next.length > _maxEntries) {
      next.remove(next.keys.first);
    }
    await _prefs.setString(
      prefsKey,
      jsonEncode(next.map((id, r) => MapEntry(id, r.toJson()))),
    );
  }
}

abstract interface class RingtoneSetService {
  Future<String> fetchSignedUrl(String id);

  /// Streams [url] to a temp file named [filename].
  /// [onProgress] receives values 0.0–1.0 as bytes arrive.
  ///
  /// RESUMABLE: a failed attempt leaves its `.part` behind and the next one asks for the rest with
  /// a `Range` header, so [onProgress] can legitimately start above 0.
  Future<File> downloadFile(
    String url,
    String filename,
    void Function(double) onProgress,
  );

  Future<bool> canWriteSettings();

  Future<void> openWriteSettings();

  /// Registers [file] in MediaStore and sets it as the device [target] tone.
  ///
  /// [title] is the name shown in the system sound picker, sanitized natively.
  /// [mime] is the real content type registered with MediaStore.
  /// Both come from the catalog row — the file is named by ringtone id, which the user must not see.
  /// Throws [RingtoneSetException] on failure.
  ///
  /// Returns the [RingtoneRef] the tone was registered under, so a later read of the system row can
  /// recognise it. Null means only that the platform gave nothing back — the set still SUCCEEDED and
  /// nothing but the badge's match is lost.
  Future<RingtoneRef?> setRingtone(
    File file,
    RingtoneTarget target, {
    required String title,
    required String mime,
  });

  /// The tone the device is ringing with RIGHT NOW, read off `Settings.System` natively.
  ///
  /// The system is the source of truth: the user may have changed the tone outside Arul, and nothing
  /// cached here would know. Null on an absent row, an unreadable one, or no platform at all — an
  /// unreadable tone is "no badge", never an error the Set flow has to handle.
  Future<RingtoneRef?> readCurrentRingtone();
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
    final tmpDir = await getTemporaryDirectory();
    final file = File('${tmpDir.path}/$filename');

    final part = File('${file.path}.part');
    var have = await part.exists() ? await part.length() : 0;

    final request = http.Request('GET', Uri.parse(url));
    if (have > 0) request.headers['Range'] = 'bytes=$have-';
    final response = await _http.send(request);

    final resuming = have > 0 && response.statusCode == 206;
    if (response.statusCode != 200 && !resuming) {
      if (response.statusCode == 416 && await part.exists()) {
        await part.delete();
      }
      throw RingtoneSetException(
        'Download failed (HTTP ${response.statusCode})',
      );
    }
    if (!resuming) have = 0;

    // `contentLength` is the BODY -> on a 206 that is only what is left, so the object is it plus
    // what is already on disk. Progress counts the same way, or a resume would restart the bar.
    final body = response.contentLength;
    final total = body == null ? null : body + have;
    var received = have;

    final sink = part.openWrite(
      mode: resuming ? FileMode.append : FileMode.write,
    );

    try {
      await response.stream.listen((List<int> chunk) {
        sink.add(chunk);
        received += chunk.length;
        if (total != null && total > 0) {
          onProgress(received / total);
        }
      }, cancelOnError: true).asFuture<void>();
      await sink.flush();
      await sink.close();

      // A cut mid-body still delivers a 200 and a short stream -> trust the LENGTH, not the status.
      if (total != null && total > 0 && received < total) {
        throw const RingtoneSetException('Download incomplete');
      }

      await part.rename(file.path);
      return file;
    } catch (_) {
      try {
        await sink.close();
      } catch (_) {
        // Already closed by the success path, or dead — either way the .part is what matters.
      }
      rethrow;
    }
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
  Future<RingtoneRef?> setRingtone(
    File file,
    RingtoneTarget target, {
    required String title,
    required String mime,
  }) async {
    try {
      final registered = await _channel.invokeMapMethod<String, Object?>(
        'setRingtone',
        {
          'filePath': file.path,
          'type': target.androidType,
          'title': title,
          'mime': mime,
        },
      );
      return RingtoneRef.fromChannel(registered);
    } on PlatformException catch (e) {
      debugPrint('[RingtoneSet] ${e.code}: ${e.message}');
      throw RingtoneSetException(e.message ?? 'Failed to set ringtone');
    }
  }

  @override
  Future<RingtoneRef?> readCurrentRingtone() async {
    try {
      return RingtoneRef.fromChannel(
        await _channel.invokeMapMethod<String, Object?>('currentRingtone'),
      );
    } catch (e) {
      // EVERY failure is the same answer: no badge. A missing plugin (tests, a host with no such
      // channel), a provider that refuses the read, a malformed payload — none of them is a problem
      // the Set flow can act on, and none may reach it as a throw.
      debugPrint('[RingtoneSet] current ringtone unreadable: $e');
      return null;
    }
  }
}
