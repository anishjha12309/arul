import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../config/app_config.dart';
import '../perf/boot_trace.dart';

// ─── Typed error ─────────────────────────────────────────────────────────────

/// Typed error thrown for any non-2xx API response.
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

  @override
  String toString() => 'ApiException($status, $code): $message';
}

// ─── Token storage keys ───────────────────────────────────────────────────────

const _kAccessTokenKey = 'arul_access_token';
const _kRefreshTokenKey = 'arul_refresh_token';

/// Locally cached identity (display name / email) so the profile UI can
/// render offline instead of going blank. Cleared together with the tokens on
/// sign-out / account deletion, so it never leaks across accounts.
const _kProfileKey = 'arul_profile';

// ─── ApiClient ────────────────────────────────────────────────────────────────

/// Wraps `http` with:
///   - Base URL from [AppConfig.apiBaseUrl]
///   - `Authorization: Bearer <accessToken>` on all requests
///   - Single-flight 401 → refresh → retry logic
///   - Typed [ApiException] on non-2xx responses
///   - Token persistence via [FlutterSecureStorage]
class ApiClient {
  ApiClient({
    FlutterSecureStorage? storage,
    http.Client? httpClient,
    this._requestTimeout = const Duration(seconds: 12),
  }) : _storage = storage ?? const FlutterSecureStorage(),
       _http = httpClient ?? http.Client();

  final FlutterSecureStorage _storage;
  final http.Client _http;

  /// Hard ceiling on every HTTP round trip (request + refresh). Without it an
  /// offline gated call — `/me/subscription`, `/media/signed-url` — hangs
  /// forever: no response, no socket error, the future just never completes,
  /// and the apply/share flow spins with no way out (confirmed on device). On
  /// timeout we throw an [http.ClientException] so [isNetworkError] classifies
  /// it as connectivity-class and the UI shows the offline message + retry
  /// instead of hanging. 12s is well past any healthy round trip, so online
  /// behavior is unchanged. Injectable for tests.
  final Duration _requestTimeout;

  /// Prevents concurrent refresh races — only one in-flight refresh at a time.
  Completer<void>? _refreshCompleter;

  /// GET paths whose response is coalesced while in flight and briefly replayed
  /// after settling (see [_meFreshFor]).
  ///
  /// Only `/me`: it now serves the cold-start auth upgrade AND the entitlement
  /// read, because the Worker LEFT JOINs the subscription row into that one
  /// response. `/me/subscription` is deliberately NOT here — no client code
  /// calls it any more (the Worker keeps the route alive only for app builds
  /// released before the merge), and listing a path nothing requests is dead
  /// config that reads as if two endpoints were still in play.
  static const Set<String> _replayableGets = {'/me'};

  /// How long a completed replayable GET may be replayed to a later caller.
  ///
  /// In-flight coalescing alone cannot collapse the cold-start pair: the
  /// optimistic auth emission and the post-`/me` profile upgrade re-resolve the
  /// entitlement provider about a second apart, so the second
  /// `/me/subscription` starts after the first has already settled and there is
  /// nothing left to join. Every authenticated cold start therefore made two
  /// identical Neon-backed round trips.
  ///
  /// A few seconds covers that gap and nothing else. It is safe for entitlement
  /// because the client copy is UX only — the real gate is the Worker's live
  /// Neon check on `/media/signed-url` (CLAUDE.md §5) — and because
  /// [invalidateMe] fires after every mutating request, so a purchase, cancel
  /// or refund is never masked by a stale snapshot.
  static const Duration _meFreshFor = Duration(seconds: 5);

  final Map<String, Future<Map<String, dynamic>>> _meInFlight = {};
  final Map<String, (Map<String, dynamic>, DateTime)> _meCache = {};

  /// Bumped by [invalidateMe]. A replayable GET that STARTED before the bump
  /// must not repopulate [_meCache] when it settles after the bump — without
  /// this, a `/me` racing a mutation could re-serve the pre-mutation
  /// entitlement for up to [_meFreshFor] after the mutation invalidated it.
  int _meEpoch = 0;

  // ─── Token management ──────────────────────────────────────────────────────

  /// Opens the encrypted-storage channel early, off the critical path.
  ///
  /// The FIRST read of a process pays for the platform channel plus Android
  /// keystore init, and on a cold start that was measured at most of the ~990ms
  /// between the first frame and the app knowing whether a session exists —
  /// which is the gate on launching Google sign-in. Called fire-and-forget from
  /// `main()`, it overlaps that cost with Firebase and prefs setup instead of
  /// serialising after them.
  ///
  /// Uses the same default [FlutterSecureStorage] instance the constructor
  /// falls back to, so this warms the channel the real read will use. Purely a
  /// cache warm: it reads nothing anyone consumes and swallows every failure,
  /// so the worst case is the old timing, never a wrong answer.
  static Future<void> warmSecureStorage() async {
    BootTrace.mark('secureStorage warm: start');
    try {
      await const FlutterSecureStorage().read(key: _kAccessTokenKey);
    } catch (_) {
      // Keystore unavailable / locked user: the real read will surface it.
    }
    BootTrace.mark('secureStorage warm: done');
  }

  /// The route [warmUp] pokes: an EXISTING public one (Digital Asset Links)
  /// that reads no DB, needs no JWT and answers from `c.env`. Deliberately not a
  /// new `/health` endpoint — the cheapest warm is one that costs the Worker
  /// nothing it isn't already built to do.
  static const _warmPath = '/.well-known/assetlinks.json';

  /// Opens DNS + TLS to the API host (and wakes a cold Worker) while the splash
  /// beat is still playing.
  ///
  /// Until this existed, `POST /auth/login` was the FIRST request of the
  /// process, so it paid the resolve, the handshake and the Worker cold start
  /// with the user watching a spinner. This runs on the SAME [http.Client], so
  /// the socket it leaves in the keep-alive pool is the one login reuses.
  ///
  /// Fire-and-forget by contract: no auth, no retry, no parsing, its own short
  /// timeout, every failure swallowed — a 404 or a 503 warms the path just as
  /// well as a 200. It must never delay or fail anything.
  Future<void> warmUp() async {
    if (!AppConfig.hasBackend) return;
    try {
      await _http.get(_uri(_warmPath)).timeout(_warmTimeout);
    } catch (_) {
      // Pure upside: a failed warm just means login pays what it used to.
    }
  }

  static const Duration _warmTimeout = Duration(seconds: 5);

  Future<String?> readAccessToken() => _storage.read(key: _kAccessTokenKey);
  Future<String?> readRefreshToken() => _storage.read(key: _kRefreshTokenKey);

  Future<void> setTokens({
    required String accessToken,
    required String refreshToken,
  }) async {
    await Future.wait([
      _storage.write(key: _kAccessTokenKey, value: accessToken),
      _storage.write(key: _kRefreshTokenKey, value: refreshToken),
    ]);
  }

  Future<void> clearTokens() async {
    // Same reason as the profile cache below, one layer up: the in-memory
    // /me + /me/subscription snapshots belong to the session being torn down.
    invalidateMe();
    await Future.wait([
      _storage.delete(key: _kAccessTokenKey),
      _storage.delete(key: _kRefreshTokenKey),
      // Drop the cached profile too so the next (or signed-out) user never sees
      // the previous user's name/email.
      _storage.delete(key: _kProfileKey),
    ]);
  }

  // ─── Profile cache ───────────────────────────────────────────────────────────

  /// Persists the user's identity locally so the profile UI survives an offline
  /// cold start (the only other source is a live `GET /me`). Null fields are
  /// dropped from the stored map.
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
    await _storage.write(key: _kProfileKey, value: jsonEncode(map));
  }

  /// Reads the locally cached profile, or null if none is stored / unparseable.
  Future<Map<String, dynamic>?> readCachedProfile() async {
    final raw = await _storage.read(key: _kProfileKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// Returns true if a stored access token exists (not validated — just presence).
  Future<bool> hasTokens() async {
    final token = await readAccessToken();
    return token != null && token.isNotEmpty;
  }

  // ─── HTTP helpers ──────────────────────────────────────────────────────────

  Uri _uri(String path) => Uri.parse('${AppConfig.apiBaseUrl}$path');

  Future<Map<String, String>> _authHeaders() async {
    final token = await readAccessToken();
    return {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
    };
  }

  // ─── Core request (with 401 retry) ─────────────────────────────────────────

  /// POSTs [body] as JSON to [path]; refreshes the token + retries once on 401.
  Future<Map<String, dynamic>> post(
    String path, {
    Map<String, dynamic>? body,
    bool requiresAuth = true,
  }) => _requestWithRetry('POST', path, body: body, requiresAuth: requiresAuth);

  /// GETs [path]; refreshes the token + retries once on 401.
  ///
  /// `/me` and `/me/subscription` are coalesced (see [_meInFlight]) and briefly
  /// reused (see [_meFreshFor]): a request already in flight is handed to every
  /// additional caller, and one that just completed is replayed.
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

    // The future stored (and returned) is the `whenComplete`-wrapped one, not
    // the raw `_requestWithRetry` future — every caller (first + joiners) ends
    // up awaiting THIS future, so the clear-on-settle side effect always runs
    // before anyone regains control.
    //
    // The callback body MUST be a block: `Map.remove` returns the removed
    // value — this very future — and a `whenComplete` callback that returns a
    // future is awaited before the wrapped future settles. An arrow body here
    // makes the future wait on itself: a permanent hang on every /me read.
    //
    // Remove-only-if-still-ours: invalidateMe() may have dropped this entry
    // and a NEWER request may already occupy the slot — blindly removing would
    // evict the newer flight and lose its coalescing.
    final epoch = _meEpoch;
    late final Future<Map<String, dynamic>> future;
    future = _requestWithRetry('GET', path, requiresAuth: requiresAuth)
        .whenComplete(() {
          if (identical(_meInFlight[path], future)) _meInFlight.remove(path);
        });
    _meInFlight[path] = future;
    // Record only on success — an error must never be replayed to a joiner
    // that arrives after the failure — and only if no mutation invalidated the
    // window while this request was in flight (see [_meEpoch]).
    unawaited(
      future
          .then((data) {
            if (epoch == _meEpoch) _meCache[path] = (data, DateTime.now());
          })
          .catchError((_) {}),
    );
    return future;
  }

  /// Drop any remembered `/me` / `/me/subscription` snapshot, forcing the next
  /// read to hit the Worker.
  ///
  /// Called automatically after every non-GET request (see [_requestWithRetry]),
  /// so no caller has to remember: a mandate setup, a cancel, or an account
  /// delete all invalidate by construction.
  ///
  /// Also detaches any in-flight replayable GET (a joiner arriving after the
  /// mutation must start a FRESH read, not adopt the pre-mutation one) and
  /// bumps [_meEpoch] so the detached flight cannot repopulate the cache when
  /// it settles.
  void invalidateMe() {
    _meCache.clear();
    _meInFlight.clear();
    _meEpoch++;
  }

  /// DELETEs [path] with an optional JSON [body]; refreshes the token +
  /// retries once on 401.
  Future<Map<String, dynamic>> delete(
    String path, {
    Map<String, dynamic>? body,
    bool requiresAuth = true,
  }) =>
      _requestWithRetry('DELETE', path, body: body, requiresAuth: requiresAuth);

  /// Core request. On a 401 (when [requiresAuth]) runs a single-flight token
  /// refresh and retries the request exactly once.
  Future<Map<String, dynamic>> _requestWithRetry(
    String method,
    String path, {
    Map<String, dynamic>? body,
    bool requiresAuth = true,
    bool isRetry = false,
  }) async {
    // Any non-GET can change what /me or /me/subscription would answer — a
    // mandate setup, a cancel, an account delete. Drop the remembered snapshot
    // up front so a caller that reads entitlement immediately after mutating it
    // can never be served the pre-mutation answer.
    if (method != 'GET') invalidateMe();

    final headers = await _authHeaders();
    final response = await _execute(method, path, headers: headers, body: body);

    if (response.statusCode == 401 && requiresAuth && !isRetry) {
      // Single-flight refresh: if another call is already refreshing, wait.
      if (_refreshCompleter != null) {
        await _refreshCompleter!.future;
      } else {
        _refreshCompleter = Completer<void>();
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
      // Retry once with new tokens.
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

  // ─── Refresh ───────────────────────────────────────────────────────────────

  /// Exchanges the stored refresh token for a new token pair; on failure clears
  /// all tokens and throws an [ApiException] (sending the user back to sign-in).
  Future<void> _doRefresh() async {
    final refreshToken = await readRefreshToken();
    if (refreshToken == null || refreshToken.isEmpty) {
      await clearTokens();
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
      // ONLY a 401 means the refresh token is genuinely dead. Everything else —
      // 429 (rate limited), 5xx, a Cloudflare gateway blip, a Neon hiccup — is
      // TRANSIENT, and wiping the session for those would sign a paying user
      // out because the server had a bad second. That is the worst possible
      // false positive: they lose premium access and have to re-authenticate,
      // for a fault that was never theirs.
      //
      // Transient failures surface as a normal error the caller can retry; the
      // stored tokens stay put and the next request succeeds. `isSessionExpired`
      // deliberately does NOT match this code, so the UI never says
      // "session expired" for what is really "server busy".
      if (response.statusCode != 401) {
        throw ApiException(
          code: 'refresh_unavailable',
          message: 'Could not reach the server. Please try again.',
          status: response.statusCode,
        );
      }
      await clearTokens();
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
      await clearTokens();
      throw const ApiException(
        code: 'invalid_refresh_response',
        message: 'Unexpected refresh response.',
        status: 500,
      );
    }
    await setTokens(accessToken: newAccess, refreshToken: newRefresh);
  }

  // ─── Response parser ───────────────────────────────────────────────────────

  /// Decodes the JSON body — returns it on 2xx, else throws a typed [ApiException].
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

  void dispose() => _http.close();
}
