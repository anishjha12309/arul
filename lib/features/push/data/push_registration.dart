import 'dart:async';

import 'package:firebase_app_installations/firebase_app_installations.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../../core/api/api_client.dart';
import '../../../core/config/build_info.dart';
import '../../../core/crash/crash_reporter.dart';

/// Puts this phone in the campaign-push registry, and keeps its row current.
///
/// **A campaign can only reach a phone that has registered**, and there is no backfill — a Firebase
/// Installation ID exists only once the app asks for one. So every build shipped before this one is
/// simply unreachable, and a new build takes about a fortnight to reach most of the active base.
/// That is the backwards-compatibility contract, not a defect to work around.
///
/// **Never on the critical path.** It is fired after `/me` has already answered, never awaited by a
/// screen, and every failure is swallowed into [CrashReporter]: a phone with no Google Play services
/// (some Huawei/Honor units) throws at `getId()`, and the right outcome there is an app that behaves
/// exactly as it did before, silently unreachable.
class PushRegistration {
  PushRegistration({
    required ApiClient apiClient,
    required this._crash,
    required this._appLanguage,
    this._fid,
    this._token,
    this._tokenRefresh,
    this._appBuild,
  }) : _api = apiClient;

  final ApiClient _api;
  final CrashReporter _crash;

  /// The app's current language code — read fresh on every call, so a language change re-registers.
  final String Function() _appLanguage;

  /// The three Firebase reads, as seams. `FirebaseInstallations` and `FirebaseMessaging` are concrete
  /// classes with no interface and their streams are STATIC, so injecting the objects would not make
  /// this testable — injecting what is actually read does. Null means "call the SDK", which is what
  /// every real build does and what `flutter test` must never reach.
  final Future<String?> Function()? _fid;
  final Future<String?> Function()? _token;
  final Stream<String>? _tokenRefresh;
  final Future<int?> Function()? _appBuild;

  StreamSubscription<String>? _tokenSub;

  /// The last body posted, so a repeat with identical values costs no request.
  /// A launch posts ONCE: `/me` landing, a sign-in completing and the locale settling all call
  /// [register], and only the first of them says anything new.
  String? _lastPosted;

  /// The registration in flight, shared by concurrent callers -> two triggers never race two writes.
  Future<void>? _inFlight;

  bool _disposed = false;

  /// Register (or refresh) this phone. Safe to call on every trigger; debounced by [_lastPosted].
  ///
  /// [force] re-posts even when the body is unchanged — the token-refresh path, where the VALUE is
  /// what moved and every other field is identical.
  Future<void> register({bool force = false}) {
    final existing = _inFlight;
    if (existing != null) return existing;
    final run = _register(force: force).whenComplete(() => _inFlight = null);
    _inFlight = run;
    return run;
  }

  Future<void> _register({required bool force}) async {
    if (_disposed) return;
    try {
      final fid =
          await (_fid?.call() ?? FirebaseInstallations.instance.getId());
      if (fid == null || fid.isEmpty) return;
      // The token is the FALLBACK target only (`message.token` is deprecated in favour of the fid),
      // so a phone that yields an id but no token still registers and is still reachable.
      final token =
          await (_token?.call() ?? FirebaseMessaging.instance.getToken())
              .catchError((Object _) => null);
      final build = await _resolveBuild();
      final sdk = await AndroidVersion.sdkInt;

      final body = <String, dynamic>{
        'fid': fid,
        if (token != null && token.isNotEmpty) 'token': token,
        'lang': _appLanguage(),
        'appBuild': ?build,
        'androidSdk': ?sdk,
      };

      final fingerprint = body.toString();
      if (!force && fingerprint == _lastPosted) return;

      await _api.post('/me/device', body: body);
      _lastPosted = fingerprint;
      debugPrint('[Push] registered $fid (${body['lang']})');
    } catch (error, stack) {
      // Never surfaced. A failed registration costs this phone the next campaign and nothing else;
      // a message about it would be noise about a feature the user never asked for.
      _crash.recordError(error, stack, reason: 'push device registration');
    }
  }

  Future<int?> _resolveBuild() async {
    try {
      if (_appBuild != null) return await _appBuild();
      final info = await PackageInfo.fromPlatform();
      return int.tryParse(info.buildNumber);
    } catch (_) {
      // A null build number costs one diagnostic column, never the registration.
      return null;
    }
  }

  /// Follow the SDK's own token rotation. FCM may mint a new token at any time (a restore, a data
  /// clear, its own 270-day garbage collection), and a stale row is a phone that silently stops
  /// receiving. `force`, because only the token moved.
  void listenForTokenRefresh() {
    if (_tokenSub != null) return;
    try {
      _tokenSub = (_tokenRefresh ?? FirebaseMessaging.instance.onTokenRefresh)
          .listen(
            (_) => unawaited(register(force: true)),
            onError: (Object e, StackTrace s) =>
                _crash.recordError(e, s, reason: 'push token refresh'),
          );
    } catch (error, stack) {
      _crash.recordError(error, stack, reason: 'push token refresh subscribe');
    }
  }

  void dispose() {
    _disposed = true;
    unawaited(_tokenSub?.cancel());
    _tokenSub = null;
  }
}
