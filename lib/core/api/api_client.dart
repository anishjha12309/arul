import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_config.dart';
import '../perf/boot_trace.dart';

class ApiException implements Exception {
  const ApiException({
    required this.code,
    required this.message,
    required this.status,
  });

  final String code;
  final String message;
  final int status;

  bool get isPremiumRequired => status == 403 && code == 'premium_required';
  bool get isUnauthorized => status == 401;

  /// No live session: the refresh token is retired for good, or there never was one (a gated call
  /// made while signed out). [ApiClient.clearTokens] has ALREADY run and [ApiClient.sessionEnded]
  /// has fired, so the wall is the next screen. A sign-out, not a defect, which is why
  /// `isNonCrashError` demotes it. A TRANSIENT refresh failure is deliberately NOT this (see
  /// `refresh_unavailable`): those keep the stored tokens, and calling them a session expiry would
  /// sign a payer out for a blip.
  bool get isSessionExpired =>
      code == 'no_refresh_token' ||
      code == 'invalid_refresh' ||
      code == 'invalid_refresh_response';

  @override
  String toString() => 'ApiException($status, $code): $message';
}

const _kAccessTokenKey = 'arul_access_token';
const _kRefreshTokenKey = 'arul_refresh_token';

/// Locally cached identity so the profile UI renders offline instead of going blank.
/// Cleared with the tokens on sign-out and account deletion -> it never leaks across accounts.
const _kProfileKey = 'arul_profile';

/// Set once, for good, when this install's Android Keystore refuses the session store.
const _kKeystoreRefusedKey = 'arul_keystore_refused';

class ApiClient {
  ApiClient({
    FlutterSecureStorage? storage,
    http.Client? httpClient,
    this._requestTimeout = const Duration(seconds: 12),
    this._plainStore,
    this._onKeystoreRefused,
  }) : _storage = storage ?? const FlutterSecureStorage(),
       _http = httpClient ?? http.Client();

  final FlutterSecureStorage _storage;
  final http.Client _http;

  /// Where the session lives once THIS install's Android Keystore has refused it: app-private
  /// storage, out of every backup and device transfer (data_extraction_rules, allowBackup=false).
  ///
  /// Some Android 8.1/9 phones' keymaster answers every key generation or load with
  /// `KeyStoreException: Memory allocation failed` (keymaster error -41), AES and RSA alike, on
  /// every retry — so no cipher option helps, and those phones could never hold a session: Google
  /// and `POST /auth/login` succeeded, then the token write threw. Owner's call: plain storage
  /// there. The switch is sticky per install ([_kKeystoreRefusedKey]) so one session never splits
  /// across two stores. Null (tests, define-less runs) = no fallback, the refusal propagates.
  final SharedPreferences? _plainStore;

  /// Told once per process when the switch happens -> a non-fatal, so the fix stays countable.
  final void Function(Object error, StackTrace stack)? _onKeystoreRefused;
  bool _refusalReported = false;

  /// Runs a session-store operation against the Keystore-backed store, or against [_plainStore]
  /// once the Keystore has refused this install. ONLY a Keystore refusal switches: the plugin's
  /// error carries the Java stack, and every refusal seen in the field runs through
  /// `android.security.keystore`. Anything else propagates exactly as before.
  Future<T> _session<T>(
    Future<T> Function(FlutterSecureStorage secure) secure,
    FutureOr<T> Function(SharedPreferences plain) plain,
  ) async {
    final store = _plainStore;
    if (store != null && (store.getBool(_kKeystoreRefusedKey) ?? false)) {
      return plain(store);
    }
    try {
      return await secure(_storage);
    } on PlatformException catch (e, stack) {
      if (store == null || !isKeystoreRefusal(e)) rethrow;
      await store.setBool(_kKeystoreRefusedKey, true);
      if (!_refusalReported) {
        _refusalReported = true;
        _onKeystoreRefused?.call(e, stack);
      }
      return plain(store);
    }
  }

  @visibleForTesting
  static bool isKeystoreRefusal(PlatformException e) =>
      '${e.message} ${e.details}'.toLowerCase().contains('keystore');

  static String _plainKey(String key) => 'arul_plain_$key';

  Future<String?> _read(String key) => _session(
    (secure) => secure.read(key: key),
    (plain) => plain.getString(_plainKey(key)),
  );

  Future<void> _write(String key, String value) => _session(
    (secure) => secure.write(key: key, value: value),
    (plain) => plain.setString(_plainKey(key), value),
  );

  Future<void> _delete(String key) => _session(
    (secure) => secure.delete(key: key),
    (plain) => plain.remove(_plainKey(key)),
  );

  /// Hard ceiling on every HTTP round trip, request and refresh alike.
  ///
  /// Without it an offline gated call hangs forever — no response, no socket error, no completion.
  /// Timing out throws [http.ClientException] -> classified connectivity-class -> offline UI + retry.
  /// 12s is well past any healthy round trip -> online behaviour is unchanged. Injectable for tests.
  final Duration _requestTimeout;

  Completer<void>? _refreshCompleter;

  /// Fires each time a refresh proves the session dead and the tokens are cleared.
  ///
  /// The auth state lives in the auth service, not here. Without this, a session that died
  /// mid-process kept the UI signed in while every gated call failed until the next cold start.
  Stream<void> get sessionEnded => _sessionEnded.stream;
  final _sessionEnded = StreamController<void>.broadcast();

  Future<void> _endSession() async {
    await clearTokens();
    if (!_sessionEnded.isClosed) _sessionEnded.add(null);
  }

  /// GET paths coalesced while in flight and briefly replayed after settling (see [_meFreshFor]).
  ///
  /// Only `/me`: the Worker LEFT JOINs the subscription row -> one response serves auth AND entitlement.
  /// `/me/subscription` is deliberately absent — nothing calls it, and a dead path reads as live config.
  static const Set<String> _replayableGets = {'/me'};

  /// How long a completed replayable GET may be replayed to a later caller.
  ///
  /// The cold-start pair re-resolves ~1s apart -> the second read starts after the first settled.
  /// In-flight coalescing alone cannot collapse that -> every cold start made two Neon round trips.
  /// A few seconds covers that gap and nothing else.
  /// Safe because the client copy is UX only — the Worker's live Neon check is the real gate (§5).
  /// [invalidateMe] fires after every mutating request -> a purchase or cancel is never masked.
  static const Duration _meFreshFor = Duration(seconds: 5);

  final Map<String, Future<Map<String, dynamic>>> _meInFlight = {};
  final Map<String, (Map<String, dynamic>, DateTime)> _meCache = {};

  /// Bumped by [invalidateMe]. A GET that STARTED before the bump must not repopulate [_meCache].
  /// Otherwise a `/me` racing a mutation re-serves pre-mutation entitlement for [_meFreshFor].
  int _meEpoch = 0;

  /// Opens the encrypted-storage channel early, off the critical path.
  ///
  /// The FIRST read of a process pays the platform channel plus Android keystore init.
  /// That was most of the ~990ms between first frame and knowing whether a session exists.
  /// Fire-and-forget from `main()` -> the cost overlaps Firebase and prefs setup, never serialises.
  /// Uses the same default [FlutterSecureStorage] the constructor falls back to -> the same channel.
  /// It reads nothing anyone consumes and swallows every failure -> worst case is the old timing.
  static Future<void> warmSecureStorage() async {
    BootTrace.mark('secureStorage warm: start');
    try {
      await const FlutterSecureStorage().read(key: _kAccessTokenKey);
    } catch (_) {
      // Keystore unavailable / locked user: the real read will surface it.
    }
    BootTrace.mark('secureStorage warm: done');
  }

  /// The route [warmUp] pokes — an EXISTING public one that reads no DB, needs no JWT, answers from env.
  /// Deliberately not a new `/health` — the cheapest warm costs the Worker nothing it does not already do.
  static const _warmPath = '/.well-known/assetlinks.json';

  /// Opens DNS + TLS to the API host, and wakes a cold Worker, while the splash is still playing.
  ///
  /// Otherwise `POST /auth/login` is the process's FIRST request and pays all three under a spinner.
  /// Runs on the SAME [http.Client] -> the socket it leaves in the keep-alive pool is login's.
  /// Fire-and-forget by contract: no auth, no retry, no parsing, short timeout, failures swallowed.
  /// A 404 or a 503 warms the path as well as a 200 -> it must never delay or fail anything.
  Future<void> warmUp() async {
    if (!AppConfig.hasBackend) return;
    try {
      await _http.get(_uri(_warmPath)).timeout(_warmTimeout);
    } catch (_) {
      // Pure upside: a failed warm just means login pays what it used to.
    }
  }

  static const Duration _warmTimeout = Duration(seconds: 5);

  Future<String?> readAccessToken() => _read(_kAccessTokenKey);
  Future<String?> readRefreshToken() => _read(_kRefreshTokenKey);

  Future<void> setTokens({
    required String accessToken,
    required String refreshToken,
  }) async {
    await Future.wait([
      _write(_kAccessTokenKey, accessToken),
      _write(_kRefreshTokenKey, refreshToken),
    ]);
  }

  Future<void> clearTokens() async {
    // The in-memory `/me` snapshot belongs to the session being torn down -> drop it with the tokens.
    invalidateMe();
    await Future.wait([
      _delete(_kAccessTokenKey),
      _delete(_kRefreshTokenKey),
      // Drop the cached profile too -> the next or signed-out user never sees the previous name.
      _delete(_kProfileKey),
    ]);
  }

  /// Persists identity locally so the profile UI survives an offline cold start — else only `GET /me`.
  /// Null fields are dropped from the stored map.
  Future<void> cacheProfile({
    String? userId,
    String? displayName,
    String? email,
  }) async {
    final map = <String, String>{
      'userId': ?userId,
      'displayName': ?displayName,
      'email': ?email,
    };
    if (map.isEmpty) return;
    await _write(_kProfileKey, jsonEncode(map));
  }

  Future<Map<String, dynamic>?> readCachedProfile() async {
    final raw = await _read(_kProfileKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<bool> hasTokens() async {
    final token = await readAccessToken();
    return token != null && token.isNotEmpty;
  }

  Uri _uri(String path) => Uri.parse('${AppConfig.apiBaseUrl}$path');

  Future<Map<String, String>> _authHeaders() async {
    final token = await readAccessToken();
    return {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
    };
  }

  Future<Map<String, dynamic>> post(
    String path, {
    Map<String, dynamic>? body,
    bool requiresAuth = true,
  }) => _requestWithRetry('POST', path, body: body, requiresAuth: requiresAuth);

  /// GETs [path]; refreshes the token + retries once on 401.
  ///
  /// `/me` is coalesced ([_meInFlight]) -> an in-flight request is handed to every extra caller.
  /// It is also briefly reused ([_meFreshFor]) -> one that just completed is replayed.
  Future<Map<String, dynamic>> get(String path, {bool requiresAuth = true}) {
    if (!_replayableGets.contains(path)) {
      return _requestWithRetry('GET', path, requiresAuth: requiresAuth);
    }
    final inFlight = _meInFlight[path];
    if (inFlight != null) return inFlight;

    final cached = _meCache[path];
    if (cached != null && DateTime.now().difference(cached.$2) < _meFreshFor) {
      return Future.value(cached.$1);
    }

    // Store and return the `whenComplete`-WRAPPED future -> clear-on-settle runs before any resume.
    // `Map.remove` returns THIS future and `whenComplete` awaits a returned future -> an arrow body
    // makes the future wait on itself: a permanent hang on every `/me` read. Keep the block body.
    // Remove only if still ours -> invalidateMe() plus a NEWER request must not lose its coalescing.
    final epoch = _meEpoch;
    late final Future<Map<String, dynamic>> future;
    future = _requestWithRetry('GET', path, requiresAuth: requiresAuth)
        .whenComplete(() {
          if (identical(_meInFlight[path], future)) _meInFlight.remove(path);
        });
    _meInFlight[path] = future;
    // Record only on SUCCESS -> an error is never replayed to a joiner arriving after the failure.
    // And only if no mutation invalidated the window mid-flight (see [_meEpoch]).
    unawaited(
      future
          .then((data) {
            if (epoch == _meEpoch) _meCache[path] = (data, DateTime.now());
          })
          .catchError((_) {}),
    );
    return future;
  }

  /// Drop any remembered `/me` snapshot, forcing the next read to hit the Worker.
  ///
  /// Called after every non-GET ([_requestWithRetry]) -> setup, cancel and delete invalidate by design.
  /// Detaches any in-flight replayable GET -> a joiner arriving after the mutation reads FRESH.
  /// Bumps [_meEpoch] -> the detached flight cannot repopulate the cache when it settles.
  void invalidateMe() {
    _meCache.clear();
    _meInFlight.clear();
    _meEpoch++;
  }

  Future<Map<String, dynamic>> delete(
    String path, {
    Map<String, dynamic>? body,
    bool requiresAuth = true,
  }) =>
      _requestWithRetry('DELETE', path, body: body, requiresAuth: requiresAuth);

  Future<Map<String, dynamic>> _requestWithRetry(
    String method,
    String path, {
    Map<String, dynamic>? body,
    bool requiresAuth = true,
    bool isRetry = false,
  }) async {
    // Any non-GET can change what `/me` would answer -> drop the remembered snapshot UP FRONT.
    // So a caller reading entitlement straight after mutating it is never served the old answer.
    if (method != 'GET') invalidateMe();

    final headers = await _authHeaders();
    final response = await _execute(method, path, headers: headers, body: body);

    if (response.statusCode == 401 && requiresAuth && !isRetry) {
      if (_refreshCompleter != null) {
        await _refreshCompleter!.future;
      } else {
        _refreshCompleter = Completer<void>();
        // Joiners await this future; the refresher gets the error by `rethrow`. With no joiner, an
        // error completion nobody listens to is an UNCAUGHT zone error -> Crashlytics logged every
        // failed refresh FATAL even when the caller caught it. Marking it handled changes nothing a
        // joiner sees.
        _refreshCompleter!.future.ignore();
        try {
          await _doRefresh();
          _refreshCompleter!.complete();
        } catch (e) {
          _refreshCompleter!.completeError(e);
          rethrow;
        } finally {
          _refreshCompleter = null;
        }
      }
      return _requestWithRetry(
        method,
        path,
        body: body,
        requiresAuth: requiresAuth,
        isRetry: true,
      );
    }

    return _parseResponse(response);
  }

  Future<http.Response> _execute(
    String method,
    String path, {
    required Map<String, String> headers,
    Map<String, dynamic>? body,
  }) {
    final uri = _uri(path);
    final encodedBody = body != null ? jsonEncode(body) : null;

    final request = switch (method) {
      'POST' => _http.post(uri, headers: headers, body: encodedBody),
      'GET' => _http.get(uri, headers: headers),
      'DELETE' => _http.delete(uri, headers: headers, body: encodedBody),
      _ => throw ArgumentError('Unsupported method: $method'),
    };
    return request.timeout(
      _requestTimeout,
      onTimeout: () => throw http.ClientException(
        'Request timed out after ${_requestTimeout.inSeconds}s',
        uri,
      ),
    );
  }

  /// Exchanges the refresh token for a new pair; a DEAD session ends it ([_endSession]) and throws.
  Future<void> _doRefresh() async {
    final refreshToken = await readRefreshToken();
    if (refreshToken == null || refreshToken.isEmpty) {
      await _endSession();
      throw const ApiException(
        code: 'no_refresh_token',
        message: 'No refresh token — please sign in again.',
        status: 401,
      );
    }

    final uri = _uri('/auth/refresh');
    final response = await _http
        .post(
          uri,
          headers: {
            'Content-Type': 'application/json',
            'Accept': 'application/json',
          },
          body: jsonEncode({'refreshToken': refreshToken}),
        )
        .timeout(
          _requestTimeout,
          onTimeout: () => throw http.ClientException(
            'Token refresh timed out after ${_requestTimeout.inSeconds}s',
            uri,
          ),
        );

    if (response.statusCode != 200) {
      // ONLY a 401 means the refresh token is genuinely dead.
      // 429, 5xx, a gateway blip, a Neon hiccup are TRANSIENT -> wiping tokens signs a payer out.
      // That is the worst false positive: premium lost and a re-auth, for a fault that was not theirs.
      // So a transient failure surfaces as a retryable error and the stored tokens stay put.
      // `isSessionExpired` deliberately does NOT match this code -> the UI never says "session expired".
      if (response.statusCode != 401) {
        throw ApiException(
          code: 'refresh_unavailable',
          message: 'Could not reach the server. Please try again.',
          status: response.statusCode,
        );
      }
      await _endSession();
      throw ApiException(
        code: 'invalid_refresh',
        message: 'Session expired — please sign in again.',
        status: response.statusCode,
      );
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final newAccess = data['accessToken'] as String?;
    final newRefresh = data['refreshToken'] as String?;
    if (newAccess == null || newRefresh == null) {
      await _endSession();
      throw const ApiException(
        code: 'invalid_refresh_response',
        message: 'Unexpected refresh response.',
        status: 500,
      );
    }
    await setTokens(accessToken: newAccess, refreshToken: newRefresh);
  }

  Map<String, dynamic> _parseResponse(http.Response response) {
    late Map<String, dynamic> json;
    try {
      json =
          jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    } catch (_) {
      throw ApiException(
        code: 'parse_error',
        message: 'Could not parse server response.',
        status: response.statusCode,
      );
    }

    if (response.statusCode >= 200 && response.statusCode < 300) {
      return json;
    }

    final error = json['error'] as Map<String, dynamic>?;
    final code = error?['code'] as String? ?? 'unknown_error';
    final message =
        error?['message'] as String? ?? 'An unexpected error occurred.';

    debugPrint('[ApiClient] ${response.statusCode} $code: $message');
    throw ApiException(
      code: code,
      message: message,
      status: response.statusCode,
    );
  }

  void dispose() {
    _http.close();
    unawaited(_sessionEnded.close());
  }
}
