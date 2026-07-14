import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../config/app_config.dart';

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

  // ─── Token management ──────────────────────────────────────────────────────

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
  Future<Map<String, dynamic>> get(String path, {bool requiresAuth = true}) =>
      _requestWithRetry('GET', path, requiresAuth: requiresAuth);

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
