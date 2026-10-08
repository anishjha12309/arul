import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../../../core/analytics/analytics_events.dart';
import '../../../core/analytics/analytics_service.dart';
import '../../../core/analytics/journey_stamps.dart';
import '../../../core/api/api_client.dart';
import '../../../core/auth/google_sign_in_init.dart';
import '../../../core/auth/session_backup.dart';
import '../../../core/config/build_info.dart';
import '../../../core/crash/crash_reporter.dart';
import '../../../core/deeplink/install_referrer_service.dart';
import '../../../core/error/app_exception.dart';
import '../../../core/perf/boot_trace.dart';
import '../domain/auth_service.dart';
import '../domain/sign_in_outcome.dart';
import 'sign_in_surface_clock.dart';

/// [AuthService] implementation backed by the Cloudflare Worker API.
/// Auth state is derived from stored tokens (no server-side session stream) -> the stream fires
/// immediately on construction, then again after every sign-in / sign-out.
class ApiAuthService implements AuthService {
  ApiAuthService({
    required ApiClient apiClient,
    required this._analytics,
    required this._crash,
    InstallReferrerService? installReferrer,
    this._appLanguage,
    this._freshInstall = false,
    SignInSurfaceClock? surfaceClock,
  }) : _api = apiClient,
       _referrer = installReferrer,
       _surfaceClock = surfaceClock ?? BindingSignInSurfaceClock() {
    // The encrypted secure-storage read can outrun a fixed brand-beat on a cold start -> sampling
    // `currentState` on a timer routes a returning user to sign-in -> the splash awaits
    // `_initialized`, which completes when this seed does.
    _initialized = _seedInitialState();
    _api.sessionEnded.listen(
      (_) => _endSession(_restored ? 'restored_expired' : 'session_expired'),
    );
  }

  late final Future<void> _initialized;

  @override
  Future<void> get initialized => _initialized;

  final ApiClient _api;
  final AnalyticsService _analytics;
  final CrashReporter _crash;

  /// True only on the very first launch of this install — the persisted cohort draw was created
  /// this process (`AnalyticsCohort.isFreshInstall`).
  final bool _freshInstall;

  /// Current app language code for the `app_language` person property set at sign-in.
  /// Optional -> tests and define-less runs need not wire a locale.
  final String Function()? _appLanguage;

  /// Optional — supplies a pending Play Install Referrer code, attached to the FIRST login -> the
  /// Worker can attribute the install.
  final InstallReferrerService? _referrer;

  /// Times how long Google's own surface took to come up, per attempt (see [SignInSurfaceClock]).
  /// Injectable so tests can hand in a fixed reading instead of driving the lifecycle.
  final SignInSurfaceClock _surfaceClock;

  final _controller = StreamController<AuthUserState>.broadcast();

  AuthUserState _current = AuthUserState.unauthenticated();

  /// Tokens exist -> authenticate OPTIMISTICALLY from the stored token and emit at once, then
  /// upgrade to the real profile via `GET /me` in the background (ApiClient auto-refreshes on 401).
  /// Sign out only on a genuine 401 (refresh failed too) -> a network/server error keeps the
  /// optimistic state so the user is not kicked out offline.
  /// Emitting before the network call -> the router leaves the splash on the storage read, not on a
  /// `/me` round-trip -> cold starts stay snappy and the Android 12+ wallpaper-apply activity
  /// recreation is a splash FLASH, not a multi-second splash-then-network wait.
  Future<void> _seedInitialState() async {
    if (_freshInstall && !await _restoreBackedSession()) {
      BootTrace.mark('authSeed: fresh install → unauthenticated');
      _wallReason = 'fresh_install';
      _emit(AuthUserState.unauthenticated());
      return;
    }

    BootTrace.mark('authSeed: hasTokens read start');
    bool hasToken;
    try {
      hasToken = await _api.hasTokens();
    } catch (e, stack) {
      _crash.recordError(e, stack, reason: 'auth seed: secure storage read');
      hasToken = false;
      _wallReason = 'storage_error';
    }
    BootTrace.mark('authSeed: hasTokens read done');
    if (!hasToken) {
      if (_wallReason == _reasonUnknown) _wallReason = 'no_session';
      _emit(AuthUserState.unauthenticated());
      return;
    }

    // 1. Optimistic: route straight to the feed off the stored token -> seed the profile from the
    //    local cache so name/email render instead of blanking while `/me` is in flight, or staying
    //    blank when offline.
    final cached = await _api.readCachedProfile();
    _emit(
      AuthUserState.authenticated(
        userId: cached?['userId'] as String? ?? 'stored',
        displayName: cached?['displayName'] as String?,
        email: cached?['email'] as String?,
      ),
    );

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
        _crash.setUserId(userId);
        // A Block Store restore never signed in here, so every event would stay anonymous. The
        // SDKs ignore a repeat of the id they already hold -> only a new identity sends anything.
        _analytics.identify(userId);
      }
    } on ApiException catch (e) {
      if (e.status == 401) {
        await _api.clearTokens();
        _endSession('session_rejected');
      }
    } catch (_) {
      // Network error: keep the optimistic authenticated state.
    }
  }

  /// A session that died on its own — no sign-out, so Google's credential state is left alone and
  /// a one-account phone can be signed straight back in. Idempotent: a refresh failure and the
  /// seed's own 401 can both land for one death.
  void _endSession(String reason) {
    if (!_current.isAuthenticated) return;
    _wallReason = reason;
    _crash.setUserId(null);
    // As on sign-out: an identified SDK ignores the next account's identify, so its events would
    // land on this user.
    _analytics.reset();
    _emit(AuthUserState.unauthenticated());
  }

  /// Why the wall is up, frozen on each `login_attempt`: the seed's verdict, a session that died
  /// (a dead refresh, or a `/me` 401 after a good one), or the person's own sign-out or deletion.
  String _wallReason = _reasonUnknown;
  static const _reasonUnknown = 'unknown';

  /// `signed_in` = a wall showing over a live session, which no path should ever do.
  @visibleForTesting
  String get wallReason => _current.isAuthenticated ? 'signed_in' : _wallReason;

  /// The seed put a Block Store session back this process -> its death is a reinstall's, not a
  /// session that lived here.
  bool _restored = false;

  void _emit(AuthUserState state) {
    _current = state;
    if (!_controller.isClosed) _controller.add(state);
  }

  @override
  Stream<AuthUserState> get authStateChanges => _controller.stream;

  @override
  AuthUserState get currentState => _current;

  @override
  Future<AuthResult> signInWith(
    AuthProvider provider, {
    bool auto = false,
    bool returned = false,
    bool reconnected = false,
    bool afterOffline = false,
    bool reopened = false,
    bool afterTimeout = false,
  }) {
    switch (provider) {
      case AuthProvider.google:
        return _signInWithGoogle(
          auto: auto,
          returned: returned,
          reconnected: reconnected,
          afterOffline: afterOffline,
          reopened: reopened,
          afterTimeout: afterTimeout,
        );
    }
  }

  @override
  Future<void> updateDisplayName(String name) async {
    final trimmed = name.trim();
    final data = await _api.post('/me/profile', body: {'displayName': trimmed});
    final user = data['user'] as Map<String, dynamic>?;
    final newName = user?['displayName'] as String? ?? trimmed;

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
    final sw = Stopwatch()..start();
    final refreshToken = await _api.readRefreshToken();
    if (refreshToken != null && refreshToken.isNotEmpty) {
      try {
        await _api.post('/auth/logout', body: {'refreshToken': refreshToken});
      } catch (e) {
        debugPrint('[ApiAuthService] logout request failed (non-fatal): $e');
      }
    }
    await _api.clearTokens();
    await _clearGoogleCredentialState();
    _crash.setUserId(null);
    // BEFORE the emit: the wall it raises fires sign-in events that must land on a fresh identity.
    _analytics.reset();
    _wallReason = 'signed_out';
    _emit(AuthUserState.unauthenticated());
    // Timing mark, readable in profile (and in a DIAG release): the baseline
    // harness reads logout duration — denylist round-trip + token clear — from
    // this line. Release builds are silent by design, so measure on profile.
    debugPrint('[ApiAuthService] signed out in ${sw.elapsedMilliseconds}ms');
  }

  Future<void> _clearGoogleCredentialState() async {
    try {
      await GoogleSignInInit.ready;
      await GoogleSignIn.instance.signOut();
    } catch (e) {
      debugPrint(
        '[ApiAuthService] clearCredentialState failed (non-fatal): $e',
      );
    }
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
    await _clearGoogleCredentialState();
    _crash.setUserId(null);
    _analytics.reset();
    _wallReason = 'account_deleted';
    _emit(AuthUserState.unauthenticated());
  }

  /// Monotonic attempt counter backing [abandonPendingSignIn]. Captured at
  /// launch, re-checked the moment `authenticate()` returns: a mismatch means
  /// the controller's stall guard gave up on this attempt while Credential
  /// Manager sat on its callback, so the revived result must be dropped
  /// before tokens, session state or analytics are touched.
  int _attemptSeq = 0;

  @override
  void abandonPendingSignIn() {
    _attemptSeq++;
  }

  AuthFailure _googleFailure(
    AuthFailureKind kind,
    String message, {
    String? error,
    String? gisCode,
  }) {
    _analytics.track(
      'login_failed',
      properties: {
        ...attemptAnalytics,
        'provider': 'google',
        'kind': kind.name,
        'error': ?_trimForAnalytics(error),
        'gis_code': ?gisCode,
      },
    );
    _noteOutcome('failed:${kind.name}');
    return AuthFailure(message: message, kind: kind);
  }

  /// Wall-clock since the CURRENT `authenticate()` call started, or null when
  /// the failure happened before it (config guard, unsupported device).
  int? get _msSinceAuthenticate => _authClock?.elapsedMilliseconds;

  /// Started immediately before the FIRST Google surface of the attempt and
  /// left running across a sheet→button escalation (one attempt, one clock);
  /// see [_msSinceAuthenticate].
  Stopwatch? _authClock;

  /// Wall-clock from the attempt's `authenticate()` to the FIRST inactive/paused/hidden — Google's
  /// own surface coming up over ours. Null means no surface was ever seen (see
  /// [SignInSurfaceClock]). This is the split `ms_since_authenticate` cannot make: it separates the
  /// PHONE'S wait (Google slow to draw) from the PERSON'S (a picker sat on and dismissed).
  int? get _msToSurface => _surfaceClock.msToSurface;

  /// TRUE when Credential Manager closed a BUTTON-flow session the user never touched.
  @visibleForTesting
  static bool isSelectorStrip({
    required String? surface,
    required String? description,
  }) {
    if (surface != _surfaceButton &&
        surface != _surfaceButtonAfterDismiss &&
        surface != _surfaceButtonAfterAddAccount &&
        surface != _surfaceButtonAfterOffline) {
      return false;
    }
    final message = description?.trim();
    if (message == null || message.isEmpty) return false;
    final bare = message.endsWith('.')
        ? message.substring(0, message.length - 1)
        : message;
    return bare == 'User cancelled the selector' ||
        bare == 'User canceled the selector';
  }

  SignInOutcome _outcomeFor(String? description) => classifySignInOutcome(
    description: description,
    msSinceAuthenticate: _msSinceAuthenticate,
    msToSurface: _msToSurface,
  );

  /// The cuts PostHog cannot make from its own properties, on every sign-in event rather than a new
  /// one: where the install came from, the poster rule, which try of the install this is, how long
  /// the person had been in the app, and the link as it stood behind Google's surface.
  Map<String, Object> get _attemptProps => {
    ...?_referrer?.attributionProps,
    'low_ram': ?DeviceMemory.resolved,
    if (_attemptN > 0) 'attempt_n': _attemptN,
    'ms_since_launch': JourneyStamps.msSinceLaunch,
    ..._history,
    ...JourneyStamps.networkFacts,
    ...JourneyStamps.renderProps,
    ...JourneyStamps.geoProps,
    'warm_ms': ?_api.firstWarmUpMs,
  };

  /// 0 until this attempt's `login_attempt` fires -> a failure before it names no try.
  int _attemptN = 0;

  /// Frozen at `login_attempt` -> every event of the attempt reports what came BEFORE it.
  Map<String, Object> _history = const {};

  void _noteOutcome(String outcome) => JourneyStamps.noteSignInOutcome(outcome);

  @override
  Map<String, Object?> get attemptAnalytics => {
    ..._attemptProps,
    'surface': ?_surface,
    'ms_since_authenticate': ?_msSinceAuthenticate,
    'ms_to_surface': ?_msToSurface,
  };

  Map<String, Object?> _cancelProperties({
    String? description,
    SignInOutcome? outcome,
  }) => {
    ...attemptAnalytics,
    'provider': 'google',
    'nudge': (outcome ?? _outcomeFor(description)).name,
    'description': ?_trimForAnalytics(description),
  };

  /// The Worker's `analytics` object from `POST /auth/login`, spread onto `login_success` as-is:
  /// scalar values only, strings capped for GA4, so a server change can never break the event.
  @visibleForTesting
  static Map<String, Object> loginAnalytics(Object? raw) {
    if (raw is! Map) return const {};
    final out = <String, Object>{};
    for (final MapEntry(:key, :value) in raw.entries) {
      if (key is! String || out.length >= 24) continue;
      switch (value) {
        case bool() || num():
          out[key] = value as Object;
        case final String s:
          out[key] = _trimForAnalytics(s)!;
      }
    }
    return out;
  }

  static String? _trimForAnalytics(String? s) =>
      s == null || s.length <= 100 ? s : s.substring(0, 100);

  /// Runs [post], retrying connectivity-class failures ([isNetworkError])
  /// until [maxAttempts] are spent or [elapsedCap] has passed since the first
  /// attempt started. A 4xx is final; a 5xx gets ONE more try (a data-centre
  /// blip answers 500 for one request and 200 for the next).
  /// An attempt still pending after [hedgeAfter] gets a second one BESIDE it,
  /// never instead of it: on a 2G link the first is usually almost through,
  /// and whichever answers first wins. The login upsert is idempotent.
  /// Pure and static so tests pin the policy without a platform channel.
  @visibleForTesting
  static Future<Map<String, dynamic>> postWithNetworkRetry(
    Future<Map<String, dynamic>> Function() post, {
    int maxAttempts = 3,
    Duration elapsedCap = const Duration(seconds: 15),
    Duration backoff = const Duration(milliseconds: 1500),
    Duration hedgeAfter = const Duration(seconds: 8),
    void Function()? onRetry,
  }) {
    final done = Completer<Map<String, dynamic>>();
    final clock = Stopwatch()..start();
    var attempts = 0;
    var pending = 0;
    var serverRetried = false;
    Object? serverError;
    StackTrace? serverStack;
    Timer? hedge;

    bool mayStartAnother() =>
        !done.isCompleted &&
        serverError == null &&
        attempts < maxAttempts &&
        clock.elapsed < elapsedCap;

    late void Function() launch;
    void settleIfIdle(Object e, StackTrace s) {
      if (pending > 0 || done.isCompleted) return;
      hedge?.cancel();
      // A server answer outranks a network error from a sibling attempt.
      done.completeError(serverError ?? e, serverStack ?? s);
    }

    launch = () {
      attempts++;
      pending++;
      hedge?.cancel();
      hedge = Timer(hedgeAfter, () {
        if (pending == 1 && mayStartAnother()) {
          onRetry?.call();
          launch();
        }
      });
      post().then(
        (data) {
          pending--;
          if (done.isCompleted) return;
          hedge?.cancel();
          done.complete(data);
        },
        onError: (Object e, StackTrace s) {
          pending--;
          if (done.isCompleted) return;
          final serverBlip = _serverBlip(e) && !serverRetried;
          if (!isNetworkError(e) && !_keysUnavailable(e) && !serverBlip) {
            serverError ??= e;
            serverStack ??= s;
            settleIfIdle(e, s);
            return;
          }
          if (serverBlip) serverRetried = true;
          if (pending == 0 && mayStartAnother()) {
            onRetry?.call();
            hedge?.cancel();
            Timer(backoff, () {
              if (!done.isCompleted) launch();
            });
            return;
          }
          settleIfIdle(e, s);
        },
      );
    };
    launch();
    return done.future;
  }

  /// The Worker could not fetch Google's signing keys: the token was never judged, so a second try
  /// is safe, where every other server answer is final.
  static bool _keysUnavailable(Object e) =>
      e is ApiException && e.code == 'google_keys_unavailable';

  /// Any other 5xx: the login is an idempotent upsert, so a repeat cannot make a second user.
  static bool _serverBlip(Object e) =>
      e is ApiException && e.status >= 500 && !_keysUnavailable(e);

  /// A reinstall (or a restored phone) whose session Block Store kept: the tokens go back into
  /// storage and the seed continues as a stored session, whose first 401 refreshes it or, if it is
  /// dead, ends it back on the wall. Capped, because every fresh install's sheet waits on the read.
  Future<bool> _restoreBackedSession() async {
    final backed = await SessionBackup.read(cap: _restoreCap);
    final access = backed?['a'];
    final refresh = backed?['r'];
    if (backed == null || access == null || refresh == null) return false;
    try {
      await _api.setTokens(accessToken: access, refreshToken: refresh);
      await _api.cacheProfile(
        userId: backed['userId'],
        displayName: backed['displayName'],
        email: backed['email'],
      );
      BootTrace.mark('authSeed: session restored from Block Store');
      _restored = true;
      return true;
    } catch (e, stack) {
      _crash.recordError(e, stack, reason: 'auth seed: session restore');
      return false;
    }
  }

  static const _restoreCap = Duration(milliseconds: 600);

  /// Which Google surface the CURRENT attempt is on. Analytics data only —
  /// never a branch condition. Null until a surface is actually opened, so a
  /// failure before that (config guard, unsupported device) blames neither.
  String? _surface;

  static const _surfaceSheet = 'sheet';
  static const _surfaceButton = 'button';

  static const _surfaceSheetReturn = 'sheet_return';

  static const _surfaceSheetReconnect = 'sheet_reconnect';

  static const _surfaceSheetAfterOffline = 'sheet_after_offline';

  /// The sheet's reported name for an attempt, given which re-arm fired it.
  @visibleForTesting
  static String sheetSurfaceFor({
    required bool returned,
    bool reconnected = false,
    bool afterOffline = false,
  }) => returned
      ? _surfaceSheetReturn
      : afterOffline
      ? _surfaceSheetAfterOffline
      : reconnected
      ? _surfaceSheetReconnect
      : _surfaceSheet;

  static const _surfaceButtonAfterAddAccount = 'button_after_add_account';

  static const _surfaceButtonAfterOffline = 'button_after_offline';

  /// [afterOffline] on the button flow is a pill tap parked while the phone had no network.
  @visibleForTesting
  static String buttonSurfaceFor({
    required bool reopened,
    bool afterOffline = false,
    bool afterTimeout = false,
  }) => reopened
      ? _surfaceButtonAfterAddAccount
      : afterOffline
      ? _surfaceButtonAfterOffline
      : afterTimeout
      ? _surfaceButtonAfterTimeout
      : _surfaceButton;

  static const _surfaceButtonAfterTimeout = 'button_after_timeout';

  /// The picker's "no credential" is Play services timing out, not an empty phone: with no Google
  /// account the button flow opens add-account instead. Matched on the plugin's own prefix.
  @visibleForTesting
  static bool isProviderTimeout({
    required String? surface,
    required GoogleSignInException e,
  }) =>
      (surface?.startsWith(_surfaceButton) ?? false) &&
      e.code == GoogleSignInExceptionCode.unknownError &&
      (e.description?.startsWith('No credential available') ?? false);

  static const _surfaceButtonAfterDismiss = 'button_after_dismiss';

  /// KILL SWITCH for sheet-first: `false` restores the previous behaviour —
  /// the button flow only, on every attempt.
  @visibleForTesting
  static const bool sheetFirst = true;

  /// ESCALATE a DISMISSED sheet to the account picker instead of stopping.
  /// `false` restores the guide's default — a dismissal ends the attempt and
  /// the wall's pill is the user's next surface.
  @visibleForTesting
  static const bool pickerAfterDismiss = true;

  /// The surface ORDER of Google's SIWG implementation guide, kept pure and
  /// generic so the contract is pinnable without a platform channel.
  /// [sheet] is null when this attempt must not open one at all (a pill tap,
  /// or the kill switch off). Its FUTURE may be null too — the plugin's
  /// "no lightweight flow on this platform", handled exactly like a null
  /// credential.
  @visibleForTesting
  ///
  /// [sheetSurface] is the NAME this attempt's sheet reports itself under — `sheet`, or
  /// `sheet_return` for the one a return to the wall re-armed. A label, never a branch: the order
  /// and the escalation below are identical either way, and a picker that follows a dismissal is
  /// still `button_after_dismiss`, so the return marker lives on its `login_attempt` alone.
  static Future<T> resolveGoogleCredential<T extends Object>({
    required Future<T?>? Function()? sheet,
    required Future<T> Function() button,
    required void Function(String surface) onSurface,
    required void Function(GoogleSignInException e) onSheetUnavailable,
    String sheetSurface = _surfaceSheet,
    String buttonSurface = _surfaceButton,
  }) async {
    if (sheet != null) {
      onSurface(sheetSurface);
      try {
        final pending = sheet();
        final credential = pending == null ? null : await pending;
        if (credential != null) return credential;
      } on GoogleSignInException catch (e) {
        if (e.code == GoogleSignInExceptionCode.canceled) {
          if (!pickerAfterDismiss) rethrow;
          onSurface(_surfaceButtonAfterDismiss);
          return button();
        }
        onSheetUnavailable(e);
      }
    }
    onSurface(buttonSurface);
    return button();
  }

  Future<AuthResult> _signInWithGoogle({
    required bool auto,
    required bool returned,
    required bool reconnected,
    required bool afterOffline,
    required bool reopened,
    bool afterTimeout = false,
  }) async {
    final attempt = ++_attemptSeq;
    // Clear first: a failure BEFORE any surface opened (unsupported device,
    // config guard) must not report the PREVIOUS attempt's elapsed time or
    // surface, and a fresh attempt never inherits a stale pill subtitle.
    _authClock = null;
    _surface = null;
    _attemptN = 0;
    _history = const {};
    JourneyStamps.forgetNetwork();
    // Drops any reading a previous attempt left behind -> a config-guard failure here can never
    // report the last attempt's wait for Google.
    _surfaceClock.endAttempt();
    SignInPhase.exchanging.value = false;
    try {
      await GoogleSignInInit.ready;

      if (!GoogleSignIn.instance.supportsAuthenticate()) {
        return _googleFailure(
          AuthFailureKind.noPlayServices,
          'Google one-tap is not supported on this device. Please update Google Play Services.',
        );
      }

      final useSheet = sheetFirst && auto;
      // The re-arm markers ride the sheet's NAME: an attempt with no sheet is a pill tap, which
      // neither a return nor a reconnect ever is.
      final sheetSurface = sheetSurfaceFor(
        returned: returned,
        reconnected: reconnected,
        afterOffline: afterOffline,
      );
      final buttonSurface = buttonSurfaceFor(
        reopened: reopened,
        afterOffline: afterOffline && !auto,
        afterTimeout: afterTimeout,
      );
      _history = JourneyStamps.signInHistory();
      _attemptN = JourneyStamps.nextAttempt() ?? 0;
      _analytics.track(
        'login_attempt',
        properties: {
          ..._attemptProps,
          'provider': 'google',
          'surface': useSheet ? sheetSurface : buttonSurface,
          'auto': auto,
          'wall_reason': wallReason,
        },
      );

      BootTrace.mark('signIn: google surface opening');
      // ONE clock for the whole attempt, left RUNNING deliberately: the
      // property means "elapsed since the first Google surface opened", so a
      // button step that follows an undrawable sheet keeps counting, and a
      // failure later in the flow (token exchange, POST /auth/login) reports
      // its own real elapsed time rather than freezing at the surface's.
      _authClock = Stopwatch()..start();
      // Same zero as [_authClock]; it stops at the first inactive/paused/hidden, which is Google's
      // surface arriving over ours -> the only signal the app gets that the sheet is up.
      _surfaceClock.startAttempt(
        onSurface: (ms) {
          _analytics.track(
            'login_surface_shown',
            properties: {
              ..._attemptProps,
              'provider': 'google',
              'surface': ?_surface,
              'auto': auto,
              'ms_to_surface': ms,
            },
          );
          SignInPhase.signals.add(SignInSignal.surfaceShown);
          unawaited(_api.prepareForExchange());
          // Only now, with Google's request already out: a channel call queued BEFORE it would
          // hold the credential request behind our own native work on the main thread.
          unawaited(JourneyStamps.probeNetwork());
          unawaited(JourneyStamps.probeDeviceFacts());
        },
      );
      final account = await resolveGoogleCredential<GoogleSignInAccount>(
        sheet: useSheet
            ? () => GoogleSignIn.instance.attemptLightweightAuthentication(
                reportAllExceptions: true,
              )
            : null,
        button: () {
          BootTrace.mark('signIn: authenticate() called');
          return GoogleSignIn.instance.authenticate();
        },
        sheetSurface: sheetSurface,
        buttonSurface: buttonSurface,
        onSurface: (surface) => _surface = surface,
        onSheetUnavailable: (e) => _analytics.track(
          'sheet_unavailable',
          properties: {
            'provider': 'google',
            'gis_code': e.code.name,
            'description': ?_trimForAnalytics(e.description),
            'ms_since_authenticate': ?_msSinceAuthenticate,
          },
        ),
      );
      BootTrace.mark('signIn: credential in hand (surface=$_surface)');
      // Google's share of the attempt; `ms_exchange` below is ours -> the two never blur again.
      final msCredential = _msSinceAuthenticate;

      if (attempt != _attemptSeq) return const AuthCancelled();

      final idToken = account.authentication.idToken;
      if (idToken == null) {
        return _googleFailure(
          AuthFailureKind.tokenExchangeFailed,
          'Failed to retrieve authentication token. Please try again.',
        );
      }

      // Exchange Google ID token for our own Worker-issued JWT pair,
      // retrying connectivity-class failures (see postWithNetworkRetry for
      // the measured failure modes and the budget math). Losing this POST
      // with the credential already in hand was the one reproducible loss in
      // the 2026-08-31 device matrix — GMS survives blackouts this request
      // did not, and without the retry the user is sent back through a
      // SECOND account picker for a failure that was never Google's. Safe to
      // retry: the Worker login is an idempotent upsert keyed on google_sub,
      // and a pair minted by a lost attempt is never stored (ages out
      // server-side).
      BootTrace.mark('signIn: POST /auth/login start');
      // The credential is in hand, so the rest of the wait is OURS — the pill
      // subtitle says so from here (see SignInPhase).
      SignInPhase.exchanging.value = true;
      var exchangeRetried = false;
      final exchangeClock = Stopwatch()..start();
      final data = await postWithNetworkRetry(
        () => _api.post(
          '/auth/login',
          body: {'idToken': idToken, 'nonce': ?GoogleSignInInit.nonce},
          requiresAuth: false,
          withToken: false,
          timeout: const Duration(seconds: 15),
        ),
        onRetry: () {
          exchangeRetried = true;
          BootTrace.mark('signIn: POST /auth/login retry after network error');
        },
      );
      BootTrace.mark('signIn: POST /auth/login done');
      final msExchange = exchangeClock.elapsedMilliseconds;

      final accessToken = data['accessToken'] as String?;
      final refreshToken = data['refreshToken'] as String?;
      final user = data['user'] as Map<String, dynamic>?;

      if (accessToken == null || refreshToken == null || user == null) {
        return _googleFailure(
          AuthFailureKind.serverError,
          'Sign-in failed. Please try again.',
          error: 'incomplete_login_payload',
        );
      }

      final userId = user['id'] as String?;
      if (userId == null) {
        return _googleFailure(
          AuthFailureKind.serverError,
          'Sign-in failed. Please try again.',
          error: 'login_payload_missing_user_id',
        );
      }

      // Re-checked HERE, not just after authenticate(): the contract is that
      // an abandoned attempt produces NO side effect, and the exchange above
      // (the Firebase-id await has no timeout of its own, the POST up to 12s)
      // can outlive a stall-guard abandon too. Without this, a zombie that
      // revived mid-exchange stored its tokens and emitted authenticated
      // AFTER the retry pill was re-armed — and if the user had already
      // retried with a DIFFERENT account, the stale attempt's tokens would
      // clobber the fresh session. The minted pair is simply never stored;
      // it ages out server-side.
      if (attempt != _attemptSeq) return const AuthCancelled();

      await _api.setTokens(
        accessToken: accessToken,
        refreshToken: refreshToken,
      );
      _restored = false;

      final displayName = user['displayName'] as String? ?? account.displayName;
      final email = user['email'] as String?;

      _emit(
        AuthUserState.authenticated(
          userId: userId,
          displayName: displayName,
          email: email,
        ),
      );
      // Not awaited: a keystore write stood between the exchange and the feed. clearTokens waits for it.
      unawaited(
        _api
            .cacheProfile(
              userId: userId,
              displayName: displayName,
              email: email,
            )
            .catchError((Object _) {}),
      );

      final server = loginAnalytics(data['analytics']);
      _analytics.identify(
        userId,
        userProperties: {
          'display_name': displayName,
          'provider': 'google',
          'app_language': ?_appLanguage?.call(),
          // Person properties ride the identify the app already sends: the server-side
          // subscription events carry no channel or phone, and break down by these instead.
          ...?_referrer?.attributionProps,
          'device_tier': ?(DeviceQuality.isResolved
              ? DeviceQuality.resolved.name
              : null),
          ...JourneyStamps.deviceFacts,
          'is_internal': ?server['internal'],
        },
      );
      _crash.setUserId(userId);
      JourneyStamps.markLogin();
      _noteOutcome('success');
      _analytics.track(
        ArulEvents.loginSuccess,
        properties: {
          ..._attemptProps,
          ...server,
          'ms_credential': ?msCredential,
          'ms_exchange': msExchange,
          'provider': 'google',
          // Which Google surface landed it, and how long the attempt took —
          // the pair that says whether sheet-first is working.
          'surface': ?_surface,
          'ms_since_authenticate': ?_msSinceAuthenticate,
          'ms_to_surface': ?_msToSurface,
          // Present only when the exchange was saved by the network retry —
          // the field readout for whether the retry earns its keep.
          if (exchangeRetried) 'exchange_retried': true,
        },
      );

      return AuthSuccess(userId: userId);
    } on GoogleSignInException catch (e) {
      debugPrint(
        '[ApiAuthService] GoogleSignInException ${e.code.name}: ${e.description}',
      );
      final mapped = mapGoogleSignInException(e);
      // The outcome the screen will speak to, classified ONCE and carried on the result — the
      // event and the line the user reads must never be able to disagree.
      var result = mapped;
      switch (mapped) {
        case AuthCancelled():
          if (isSelectorStrip(surface: _surface, description: e.description)) {
            debugPrint(
              '[ApiAuthService] selector stripped by the OS (surface=$_surface)',
            );
            result = const AuthCancelled(
              outcome: SignInOutcome.selectorStripped,
            );
            break;
          }
          final outcome = _outcomeFor(e.description);
          // Field triage: the classifier's verdict and the two clocks behind it, in one line.
          // Silenced in a Play release like every other debugPrint; a DIAG sideload gets it back.
          debugPrint(
            '[ApiAuthService] cancel outcome=${outcome.name} '
            'ms_to_surface=$_msToSurface ms_since_authenticate=$_msSinceAuthenticate',
          );
          result = AuthCancelled(outcome: outcome);
          _analytics.track(
            'login_cancelled',
            properties: _cancelProperties(
              description: e.description,
              outcome: outcome,
            ),
          );
          _noteOutcome('cancelled:${outcome.name}');
        case AuthFailure(:final kind, :final message):
          _googleFailure(
            kind,
            message,
            gisCode: e.code.name,
            error: e.description,
          );
          if (isProviderTimeout(surface: _surface, e: e)) {
            result = AuthFailure(
              message: message,
              kind: kind,
              providerTimedOut: true,
            );
          }
        case AuthSuccess():
          break; // unreachable: the mapper never returns success
      }
      return result;
    } on PlatformException catch (e) {
      return _mapPlatformException(e);
    } on ApiException catch (e) {
      return _googleFailure(
        AuthFailureKind.serverError,
        e.message,
        error: e.message,
      );
    } catch (e) {
      // Last-resort fallback for non-GIS, non-platform exceptions only —
      // GoogleSignInException above owns the plugin's outcomes now.
      if (isNetworkError(e)) {
        return _googleFailure(
          AuthFailureKind.networkError,
          "Couldn't reach the server. Check your internet connection and try again.",
          error: e.toString(),
        );
      }
      final msg = e.toString().toLowerCase();
      if (msg.contains('cancel') || msg.contains('user_cancelled')) {
        // A raw exception's `toString()` is never one of the Credential Manager messages, so the
        // classifier lands on the plain retry line — which is the truth here: we do not know.
        final outcome = _outcomeFor(e.toString());
        _analytics.track(
          'login_cancelled',
          properties: _cancelProperties(
            description: e.toString(),
            outcome: outcome,
          ),
        );
        _noteOutcome('cancelled:${outcome.name}');
        return AuthCancelled(outcome: outcome);
      }
      debugPrint('[ApiAuthService] unexpected error: $e');
      return _googleFailure(
        AuthFailureKind.unknown,
        'Sign-in failed. Please try again.',
        error: e.toString(),
      );
    } finally {
      // Identity-checked like every other side effect here: a zombie finishing
      // late must not reset the pill — or unhook the surface clock — of the
      // attempt that replaced it.
      if (attempt == _attemptSeq) {
        SignInPhase.exchanging.value = false;
        _surfaceClock.endAttempt();
      }
      SignInPhase.signals.add(SignInSignal.settled);
    }
  }

  /// Pure classification of a v7 [GoogleSignInException] — kept static and
  /// side-effect-free so tests can pin every code's mapping. The enum is
  /// documented as non-exhaustive ("adding new values will not be considered
  /// a breaking change"), so unknown codes MUST fall through to a generic
  /// failure, never crash and never go quiet.
  @visibleForTesting
  static AuthResult mapGoogleSignInException(GoogleSignInException e) {
    switch (e.code) {
      case GoogleSignInExceptionCode.canceled:
        return const AuthCancelled();
      case GoogleSignInExceptionCode.interrupted:
        // "Interrupted for a reason other than being intentionally canceled"
        // — in practice a network/GMS hiccup mid-flow. Retryable.
        return const AuthFailure(
          message:
              'Sign-in was interrupted. Please check your connection and try again.',
          kind: AuthFailureKind.networkError,
        );
      case GoogleSignInExceptionCode.providerConfigurationError:
        return const AuthFailure(
          message:
              'Google Play Services is unavailable. Please update or reinstall.',
          kind: AuthFailureKind.noPlayServices,
        );
      default:
        // clientConfigurationError, uiUnavailable, userMismatch, unknownError
        // and any code a future plugin version adds: visible + retryable.
        return const AuthFailure(
          message:
              "Sign-in didn't complete. Check your internet connection and try again.",
          kind: AuthFailureKind.unknown,
        );
    }
  }

  /// Fallback for a raw platform error. With v7 the plugin's own outcomes all
  /// arrive as [GoogleSignInException], so this now only catches what escapes
  /// it — which is why the "cancel" string match survives HERE and nowhere
  /// else: it is no longer the classifier for a real sign-in. Every branch
  /// tracks, so no outcome leaves the app unaccounted for.
  AuthFailure _mapPlatformException(PlatformException e) {
    debugPrint('[ApiAuthService] PlatformException ${e.code}: ${e.message}');
    final code = e.code.toLowerCase();
    final message = e.message?.toLowerCase() ?? '';

    if (code.contains('cancel') || message.contains('cancel')) {
      _analytics.track(
        'login_cancelled',
        properties: _cancelProperties(description: e.message),
      );
      _noteOutcome('cancelled:platform');
      return const AuthFailure(
        message: 'Sign-in was cancelled.',
        kind: AuthFailureKind.unknown,
      );
    }
    if (code == 'network_error' || message.contains('network')) {
      return _googleFailure(
        AuthFailureKind.networkError,
        'Network error. Please check your connection and try again.',
      );
    }
    if (message.contains('play services') ||
        code.contains('play_services') ||
        code == '7') {
      return _googleFailure(
        AuthFailureKind.noPlayServices,
        'Google Play Services is unavailable. Please update or reinstall.',
      );
    }
    return _googleFailure(
      AuthFailureKind.unknown,
      e.message ?? 'Sign-in failed. Please try again.',
      error: e.message,
    );
  }
}
