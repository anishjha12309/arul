import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../../../core/analytics/analytics_service.dart';
import '../../../core/api/api_client.dart';
import '../../../core/crash/crash_reporter.dart';
import '../../referral/data/install_referrer_service.dart';
import '../domain/auth_service.dart';

/// [AuthService] implementation backed by the Cloudflare Worker API.
///
/// Google sign-in flow:
///   GoogleSignIn.instance.authenticate() → idToken → POST /auth/login
///
/// Auth state is derived from stored tokens (no server-side session stream).
/// The stream fires immediately on construction, then again after every
/// sign-in / sign-out.
class ApiAuthService implements AuthService {
  ApiAuthService({
    required ApiClient apiClient,
    required this._analytics,
    required this._crash,
    InstallReferrerService? installReferrer,
  }) : _api = apiClient,
       _referral = installReferrer {
    // Seed the stream with the current persisted state. `_initialized`
    // completes once this finishes so the splash can WAIT for the real
    // stored-session verdict instead of sampling `currentState` on a timer
    // (the encrypted secure-storage read can outrun a fixed brand-beat on a
    // cold start, which would route a returning user to sign-in).
    _initialized = _seedInitialState();
  }

  late final Future<void> _initialized;

  @override
  Future<void> get initialized => _initialized;

  final ApiClient _api;
  final AnalyticsService _analytics;
  final CrashReporter _crash;

  /// Optional — supplies a pending referral code (Play Install Referrer) to
  /// attach to the FIRST login so the Worker can attribute the install.
  final InstallReferrerService? _referral;

  final _controller = StreamController<AuthUserState>.broadcast();

  // Tracks the current state so [currentState] can return synchronously.
  AuthUserState _current = AuthUserState.unauthenticated();

  // ─── Initialisation ────────────────────────────────────────────────────────

  /// Checks secure storage for an existing access token and emits the right
  /// initial state.  Called once in the constructor; fire-and-forget.
  ///
  /// When tokens exist we authenticate OPTIMISTICALLY from the stored token and
  /// emit immediately, then upgrade to the real profile via `GET /me` in the
  /// background (the ApiClient auto-refreshes on 401). We sign the user out only
  /// on a genuine 401 (refresh also failed); on a network/server error we keep
  /// the optimistic state so the user isn't kicked out offline.
  ///
  /// Emitting before the network call is what keeps cold starts snappy: the
  /// router leaves the splash as soon as the token is read from secure storage,
  /// instead of stalling on a `/me` round-trip. It also makes the Android 12+
  /// wallpaper-apply activity recreation a brief splash flash rather than a
  /// multi-second splash-then-network wait. Browse/preview is public, so it's
  /// safe to show before `/me` confirms; entitlement is always re-checked live.
  Future<void> _seedInitialState() async {
    final hasToken = await _api.hasTokens();
    if (!hasToken) {
      _emit(AuthUserState.unauthenticated());
      return;
    }

    // 1. Optimistic: route straight to the feed off the stored token. Seed the
    //    profile from the local cache so the name/email render instead of
    //    going blank while `/me` is in flight — or staying blank if we're offline.
    final cached = await _api.readCachedProfile();
    _emit(
      AuthUserState.authenticated(
        userId: cached?['userId'] as String? ?? 'stored',
        displayName: cached?['displayName'] as String?,
        email: cached?['email'] as String?,
      ),
    );

    // 2. Background upgrade to the real user (or sign out if the session is dead).
    try {
      final data = await _api.get('/me');
      final user = data['user'] as Map<String, dynamic>?;
      final userId = user?['id'] as String?;
      if (userId != null) {
        final displayName = user?['displayName'] as String?;
        final email = user?['email'] as String?;
        _emit(
          AuthUserState.authenticated(
            userId: userId,
            displayName: displayName,
            email: email,
          ),
        );
        await _api.cacheProfile(
          userId: userId,
          displayName: displayName,
          email: email,
        );
        // Tie crash reports to the restored session (one of the few high-value
        // Crashlytics touch points).
        _crash.setUserId(userId);
      }
    } on ApiException catch (e) {
      if (e.status == 401) {
        await _api.clearTokens();
        _crash.setUserId(null);
        _emit(AuthUserState.unauthenticated());
      }
      // Other statuses (offline, 5xx): keep the optimistic authenticated state.
    } catch (_) {
      // Network error: keep the optimistic authenticated state.
    }
  }

  void _emit(AuthUserState state) {
    _current = state;
    if (!_controller.isClosed) _controller.add(state);
  }

  // ─── AuthService ───────────────────────────────────────────────────────────

  @override
  Stream<AuthUserState> get authStateChanges => _controller.stream;

  @override
  AuthUserState get currentState => _current;

  @override
  Future<AuthResult> signInWith(AuthProvider provider) {
    switch (provider) {
      case AuthProvider.google:
        return _signInWithGoogle();
    }
  }

  @override
  Future<void> updateDisplayName(String name) async {
    final trimmed = name.trim();
    final data = await _api.post('/me/profile', body: {'displayName': trimmed});
    final user = data['user'] as Map<String, dynamic>?;
    final newName = user?['displayName'] as String? ?? trimmed;

    // Reflect the new name in the current state so the UI updates reactively,
    // and refresh the local cache so it survives the next offline cold start.
    if (_current.isAuthenticated) {
      _emit(_current.copyWith(displayName: newName));
      await _api.cacheProfile(
        userId: _current.userId,
        displayName: newName,
        email: _current.email,
      );
    }

    _analytics.track('profile_name_updated');
    final uid = _current.userId;
    if (uid != null && uid != 'stored') {
      _analytics.identify(uid, userProperties: {'display_name': newName});
    }
  }

  @override
  Future<void> signOut() async {
    final refreshToken = await _api.readRefreshToken();
    if (refreshToken != null && refreshToken.isNotEmpty) {
      try {
        // Best-effort: denylist the refresh token on the server.
        await _api.post('/auth/logout', body: {'refreshToken': refreshToken});
      } catch (e) {
        debugPrint('[ApiAuthService] logout request failed (non-fatal): $e');
      }
    }
    await _api.clearTokens();
    _crash.setUserId(null);
    _emit(AuthUserState.unauthenticated());
  }

  @override
  Future<void> deleteAccount() async {
    // The Worker revokes the refresh token itself after a successful delete,
    // so the old session dies server-side, not just locally.
    final refreshToken = await _api.readRefreshToken();
    try {
      await _api.delete('/me', body: {'refreshToken': ?refreshToken});
    } on ApiException catch (e) {
      // 404 = the account is already gone (e.g. a retry after the previous
      // response was lost in transit). That IS the desired end state — fall
      // through and clear the local session instead of stranding a ghost login.
      if (e.status != 404) rethrow;
    }

    // Track BEFORE dropping identity so the event still carries the user id.
    _analytics.track('account_deleted');

    await _api.clearTokens();
    _crash.setUserId(null);
    _emit(AuthUserState.unauthenticated());
  }

  // ─── Google ────────────────────────────────────────────────────────────────

  Future<AuthResult> _signInWithGoogle() async {
    try {
      // v7: use the singleton; initialize() was already called in main().
      if (!GoogleSignIn.instance.supportsAuthenticate()) {
        return const AuthFailure(
          message:
              'Google one-tap is not supported on this device. Please update Google Play Services.',
          kind: AuthFailureKind.noPlayServices,
        );
      }

      final account = await GoogleSignIn.instance.authenticate();

      // v7: idToken is a synchronous property on GoogleSignInAuthentication.
      final idToken = account.authentication.idToken;
      if (idToken == null) {
        return const AuthFailure(
          message: 'Failed to retrieve authentication token. Please try again.',
          kind: AuthFailureKind.tokenExchangeFailed,
        );
      }

      // Referral attribution: attach any pending code from the Play Install
      // Referrer. The Worker only honors it on new-user creation, so re-sending
      // on later logins is harmless. Cleared after a successful exchange below.
      final referralCode = _referral?.pendingCode;

      // Exchange Google ID token for our own Worker-issued JWT pair.
      final data = await _api.post(
        '/auth/login',
        body: {
          'idToken': idToken,
          // Null-aware element: dropped entirely when there's no pending code.
          'referralCode': ?referralCode,
        },
        requiresAuth: false,
      );

      final accessToken = data['accessToken'] as String?;
      final refreshToken = data['refreshToken'] as String?;
      final user = data['user'] as Map<String, dynamic>?;

      if (accessToken == null || refreshToken == null || user == null) {
        return const AuthFailure(
          message: 'Sign-in failed. Please try again.',
          kind: AuthFailureKind.serverError,
        );
      }

      final userId = user['id'] as String?;
      if (userId == null) {
        return const AuthFailure(
          message: 'Sign-in failed. Please try again.',
          kind: AuthFailureKind.serverError,
        );
      }

      await _api.setTokens(
        accessToken: accessToken,
        refreshToken: refreshToken,
      );

      // Consumed — never re-attribute a later account on this device.
      if (referralCode != null) {
        await _referral?.clearPendingCode();
      }

      final displayName = user['displayName'] as String? ?? account.displayName;
      final email = user['email'] as String?;

      _emit(
        AuthUserState.authenticated(
          userId: userId,
          displayName: displayName,
          email: email,
        ),
      );
      await _api.cacheProfile(
        userId: userId,
        displayName: displayName,
        email: email,
      );

      _analytics.identify(
        userId,
        userProperties: {'display_name': displayName, 'provider': 'google'},
      );
      _crash.setUserId(userId);
      _analytics.track('login_success', properties: {'provider': 'google'});

      return AuthSuccess(userId: userId);
    } on PlatformException catch (e) {
      return _mapPlatformException(e);
    } on ApiException catch (e) {
      _analytics.track(
        'login_failed',
        properties: {
          'provider': 'google',
          'error': e.message,
          'kind': AuthFailureKind.serverError.name,
        },
      );
      return AuthFailure(message: e.message, kind: AuthFailureKind.serverError);
    } catch (e) {
      final msg = e.toString().toLowerCase();
      if (msg.contains('cancel') || msg.contains('user_cancelled')) {
        return const AuthCancelled();
      }
      debugPrint('[ApiAuthService] unexpected error: $e');
      _analytics.track(
        'login_failed',
        properties: {
          'provider': 'google',
          'error': e.toString(),
          'kind': AuthFailureKind.unknown.name,
        },
      );
      return AuthFailure(
        message: 'Sign-in failed. Please try again.',
        kind: AuthFailureKind.unknown,
      );
    }
  }

  AuthFailure _mapPlatformException(PlatformException e) {
    debugPrint('[ApiAuthService] PlatformException ${e.code}: ${e.message}');
    final code = e.code.toLowerCase();
    final message = e.message?.toLowerCase() ?? '';

    if (code.contains('cancel') || message.contains('cancel')) {
      return const AuthFailure(
        message: 'Sign-in was cancelled.',
        kind: AuthFailureKind.unknown,
      );
    }
    if (code == 'network_error' || message.contains('network')) {
      _analytics.track(
        'login_failed',
        properties: {
          'provider': 'google',
          'kind': AuthFailureKind.networkError.name,
        },
      );
      return const AuthFailure(
        message: 'Network error. Please check your connection and try again.',
        kind: AuthFailureKind.networkError,
      );
    }
    if (message.contains('play services') ||
        code.contains('play_services') ||
        code == '7') {
      return const AuthFailure(
        message:
            'Google Play Services is unavailable. Please update or reinstall.',
        kind: AuthFailureKind.noPlayServices,
      );
    }
    _analytics.track(
      'login_failed',
      properties: {
        'provider': 'google',
        'error': e.message,
        'kind': AuthFailureKind.unknown.name,
      },
    );
    return AuthFailure(
      message: e.message ?? 'Sign-in failed. Please try again.',
      kind: AuthFailureKind.unknown,
    );
  }
}
