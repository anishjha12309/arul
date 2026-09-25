import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../../../core/analytics/analytics_events.dart';
import '../../../core/analytics/analytics_service.dart';
import '../../../core/api/api_client.dart';
import '../../../core/auth/google_sign_in_init.dart';
import '../../../core/config/build_info.dart';
import '../../../core/crash/crash_reporter.dart';
import '../../../core/error/app_exception.dart';
import '../../../core/perf/boot_trace.dart';
import '../../referral/data/install_referrer_service.dart';
import '../domain/auth_service.dart';
import '../domain/sign_in_outcome.dart';
import 'sign_in_surface_clock.dart';

/// [AuthService] implementation backed by the Cloudflare Worker API.
///
/// Google's own "Implement Sign in with Google" guide fixes the surface order -> Credential Manager
/// BOTTOM SHEET first (automatic sign-in when exactly one authorized account exists), the "Sign in
/// with Google" BUTTON flow as the fallback for a sheet that drew nothing, a sheet that could not
/// run, and every user-initiated retry.
///   sheet | button → idToken (+ per-process nonce) → POST /auth/login
///
/// EXACTLY ONE visible Google surface per attempt -> the picker follows a sheet only when the sheet
/// drew NOTHING.
/// A sheet run as a WARM-UP ahead of a picker is a different thing and stays forbidden -> measured,
/// the user saw a drawer appear, hang and vanish, then the picker.
///
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
       _referral = installReferrer,
       _surfaceClock = surfaceClock ?? BindingSignInSurfaceClock() {
    // The encrypted secure-storage read can outrun a fixed brand-beat on a cold start -> sampling
    // `currentState` on a timer routes a returning user to sign-in -> the splash awaits
    // `_initialized`, which completes when this seed does.
    _initialized = _seedInitialState();
    // A refresh that proves the session dead mid-process is the same verdict the seed reaches on a
    // cold start -> signed out. Without it the UI stayed signed in and every gated call failed.
    _api.sessionEnded.listen((_) => _endSession());
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
  final InstallReferrerService? _referral;

  /// Times how long Google's own surface took to come up, per attempt (see [SignInSurfaceClock]).
  /// Injectable so tests can hand in a fixed reading instead of driving the lifecycle.
  final SignInSurfaceClock _surfaceClock;

  final _controller = StreamController<AuthUserState>.broadcast();

  AuthUserState _current = AuthUserState.unauthenticated();

  /// Checks secure storage for an existing access token and emits the right initial state.
  /// Called once in the constructor; fire-and-forget.
  ///
  /// Tokens exist -> authenticate OPTIMISTICALLY from the stored token and emit at once, then
  /// upgrade to the real profile via `GET /me` in the background (ApiClient auto-refreshes on 401).
  /// Sign out only on a genuine 401 (refresh failed too) -> a network/server error keeps the
  /// optimistic state so the user is not kicked out offline.
  /// Emitting before the network call -> the router leaves the splash on the storage read, not on a
  /// `/me` round-trip -> cold starts stay snappy and the Android 12+ wallpaper-apply activity
  /// recreation is a splash FLASH, not a multi-second splash-then-network wait.
  /// Browse/preview is public -> safe to show before `/me` confirms; entitlement is re-checked live.
  Future<void> _seedInitialState() async {
    // Tokens live in the app's own data dir and allowBackup is false -> no restore can resurrect
    // them -> a true first launch cannot have a stored session, so skip the read entirely.
    // An install's FIRST secure-storage read pays the keystore master-key setup (~970ms measured on
    // a profile build) -> once everything else was overlapped it was the last thing gating the
    // account picker, on exactly the launch the install→login funnel lives or dies on.
    // The freshness signal is the persisted cohort draw (AnalyticsCohort.isFreshInstall) — the one
    // durable first-launch marker, false in any process that never ran resolve() -> that degrades
    // to the keystore wait below, never to a wrong verdict.
    // main()'s warm-up still initialises the keystore in the background -> the post-login token
    // WRITE finds it ready.
    if (_freshInstall) {
      BootTrace.mark('authSeed: fresh install → unauthenticated');
      _emit(AuthUserState.unauthenticated());
      return;
    }

    BootTrace.mark('authSeed: hasTokens read start');
    bool hasToken;
    try {
      hasToken = await _api.hasTokens();
    } catch (e, stack) {
      // The Android Keystore can refuse the read outright on a low-RAM phone ("Failed to generate
      // key pair", Android 9). Escaping from here failed [initialized], the splash's await threw
      // before its `context.go`, and the app sat on the splash on EVERY launch. No readable session
      // is the same verdict as no session -> the wall, where signing in writes fresh tokens.
      _crash.recordError(e, stack, reason: 'auth seed: secure storage read');
      hasToken = false;
    }
    BootTrace.mark('authSeed: hasTokens read done');
    if (!hasToken) {
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
        // Tie crash reports to the restored session — one of the few high-value Crashlytics
        // touch points.
        _crash.setUserId(userId);
      }
    } on ApiException catch (e) {
      if (e.status == 401) {
        await _api.clearTokens();
        _endSession();
      }
    } catch (_) {
      // Network error: keep the optimistic authenticated state.
    }
  }

  /// A session that died on its own — no sign-out, so Google's credential state is left alone and
  /// a one-account phone can be signed straight back in. Idempotent: a refresh failure and the
  /// seed's own 401 can both land for one death.
  void _endSession() {
    if (!_current.isAuthenticated) return;
    _crash.setUserId(null);
    _emit(AuthUserState.unauthenticated());
  }

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
    bool reopened = false,
  }) {
    switch (provider) {
      case AuthProvider.google:
        return _signInWithGoogle(
          auto: auto,
          returned: returned,
          reconnected: reconnected,
          reopened: reopened,
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
    _emit(AuthUserState.unauthenticated());
    // Timing mark, readable in profile (and in a DIAG release): the baseline
    // harness reads logout duration — denylist round-trip + token clear — from
    // this line. Release builds are silent by design, so measure on profile.
    debugPrint('[ApiAuthService] signed out in ${sw.elapsedMilliseconds}ms');
  }

  /// Google's Credential Manager "Sign in with Google" guide, Handle sign-out:
  /// call `clearCredentialState()` so every credential provider drops its
  /// stored session for this app and "the next sign-in request gets full
  /// sign-in options". The plugin's `signOut()` is exactly that call. Without
  /// it a user who signed out to switch accounts can be handed the same
  /// account again, and Google's precondition for automatic sign-in ("the
  /// user has not explicitly signed out") is never recorded. Best-effort: the
  /// local session is already gone by the time this runs, so a plugin error
  /// must never strand the user signed in.
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

  /// Tracks a Google sign-in failure and returns it. EVERY failure return in
  /// [_signInWithGoogle] goes through here. The typed classification fixed
  /// which outcomes are QUIET; this fixes which are COUNTED — six returns
  /// showed the user an error and told analytics nothing, so those sign-ins
  /// left the install→login funnel with no trace of why.
  AuthFailure _googleFailure(
    AuthFailureKind kind,
    String message, {
    String? error,
    String? gisCode,
  }) {
    _analytics.track(
      'login_failed',
      properties: {
        ..._installProps,
        'provider': 'google',
        'kind': kind.name,
        'error': ?_trimForAnalytics(error),
        'gis_code': ?gisCode,
        'surface': ?_surface,
        'ms_since_authenticate': ?_msSinceAuthenticate,
      },
    );
    return AuthFailure(message: message, kind: kind);
  }

  /// Wall-clock since the CURRENT `authenticate()` call started, or null when
  /// the failure happened before it (config guard, unsupported device).
  ///
  /// This exists because `login_cancelled` is a MIXED bucket and cannot be read
  /// as a UX metric without it: `google_sign_in_android`'s README states that
  /// configuration errors (wrong signing SHA, wrong package name, wrong
  /// serverClientId) make Credential Manager return `canceled` AFTER the user
  /// has already picked an account, and "the plugin has no way to distinguish
  /// this case from the user canceling sign-in". A real dismissal lands in a
  /// couple of seconds; a post-selection failure lands materially later, so the
  /// elapsed time is what splits the two populations.
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

  /// What the attempt actually did, for the nudge and for `login_cancelled.nudge`.
  /// TRUE when Credential Manager closed a BUTTON-flow session the user never touched.
  ///
  /// A user backing out of Google's picker reports "[16] Cancelled by user." — GMS's own wording.
  /// "User cancelled the selector" is the FRAMEWORK's wording for its selector session ending,
  /// which on the button flow (GMS's own activity, no framework selector on screen) only happens
  /// when the OS finishes the picker under us — an app-icon launch on the live task, which
  /// `clearTaskOnLaunch` turns into exactly that. Both measured on device, same phone, same minute.
  /// On the SHEET the same string is the user's own swipe and never a strip.
  @visibleForTesting
  static bool isSelectorStrip({
    required String? surface,
    required String? description,
  }) {
    if (surface != _surfaceButton &&
        surface != _surfaceButtonAfterDismiss &&
        surface != _surfaceButtonAfterAddAccount) {
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

  /// Properties for every `login_cancelled` emission, so all three call sites
  /// carry the same shape.
  ///
  /// [description] is the Credential Manager message — the ONLY signal that
  /// splits a real dismissal ("activity is cancelled by the user") from a
  /// GMS-side abort reported as a cancel ("[16] …", "Unable to get sync
  /// account" — the official troubleshooting guide documents both). Elapsed
  /// time cannot split them: measured on device (2026-08-31), a deliberate
  /// dismissal and a mid-flow failure both land 5–30s after the auto-launched
  /// `authenticate()`, because the clock starts at launch, not at the sheet.
  ///
  /// `nudge` is the LINE THE USER WAS SHOWN for this event, so the funnel reads the copy and the
  /// outcome as one row instead of joining a message string to a screen state after the fact.
  /// Where the install came from and whether the phone is on the poster rule — the two cuts
  /// PostHog cannot make from its own properties, on every sign-in event rather than a new one.
  Map<String, Object> get _installProps => {
    ...?_referral?.attributionProps,
    'low_ram': ?DeviceMemory.resolved,
  };

  Map<String, Object?> _cancelProperties({
    String? description,
    SignInOutcome? outcome,
  }) => {
    ..._installProps,
    'provider': 'google',
    'surface': ?_surface,
    'ms_since_authenticate': ?_msSinceAuthenticate,
    'ms_to_surface': ?_msToSurface,
    'nudge': (outcome ?? _outcomeFor(description)).name,
    'description': ?_trimForAnalytics(description),
  };

  /// GA4 silently drops any parameter VALUE over 100 chars (the event
  /// survives, the property vanishes), so every free-text property is cut to
  /// fit both sinks — PostHog just gets the same first 100 chars.
  static String? _trimForAnalytics(String? s) =>
      s == null || s.length <= 100 ? s : s.substring(0, 100);

  /// Runs [post], retrying connectivity-class failures ([isNetworkError])
  /// until [maxAttempts] are spent or [elapsedCap] has passed since the first
  /// attempt started. A server RESPONSE (any [ApiException], even a 5xx) is
  /// never retried — the server spoke; retrying is the caller's decision.
  ///
  /// The two-knob shape matches the two failure modes measured on device
  /// (2026-08-31 matrix, prod bits): fully OFFLINE fails INSTANTLY
  /// (`Failed host lookup`), so the attempt budget is what matters — three
  /// tries burn ~4.5s and then fail honestly; a mid-flow BLIP kills the
  /// socket and surfaces as ApiClient's 12s timeout on a link that recovered
  /// seconds earlier (matrix RUN101: a 5s cut lost the login with the
  /// credential already in hand), so the elapsed cap is what matters — one
  /// more 12s attempt fits, a third would not. Worst case 12 + 1.5 + 12 =
  /// 25.5s, inside the stall guard's 30s continuous-foreground budget
  /// (auth_providers.dart _guard, restarted on return from the sheet).
  ///
  /// Pure and static so tests pin the policy without a platform channel.
  @visibleForTesting
  static Future<Map<String, dynamic>> postWithNetworkRetry(
    Future<Map<String, dynamic>> Function() post, {
    int maxAttempts = 3,
    Duration elapsedCap = const Duration(seconds: 15),
    Duration backoff = const Duration(milliseconds: 1500),
    void Function()? onRetry,
  }) async {
    final clock = Stopwatch()..start();
    var attempt = 0;
    while (true) {
      attempt++;
      try {
        return await post();
      } catch (e) {
        if (!isNetworkError(e)) rethrow;
        if (attempt >= maxAttempts || clock.elapsed >= elapsedCap) rethrow;
        onRetry?.call();
        await Future<void>.delayed(backoff);
      }
    }
  }

  /// Which Google surface the CURRENT attempt is on. Analytics data only —
  /// never a branch condition. Null until a surface is actually opened, so a
  /// failure before that (config guard, unsupported device) blames neither.
  String? _surface;

  static const _surfaceSheet = 'sheet';
  static const _surfaceButton = 'button';

  /// The sheet of an attempt the controller re-armed on a RETURN to the wall, kept apart from the
  /// cold-start sheet: it is the only automatic surface a person has already walked away from once,
  /// so it is the only one whose conversion says whether re-arming on a return earns its cancels.
  /// A VALUE on the existing `surface` property — no new event, no new property.
  static const _surfaceSheetReturn = 'sheet_return';

  /// The sheet of an attempt the controller re-armed when the LINK came back after a network-class
  /// failure, kept apart from both other sheets: it is the only one fired at a person who never
  /// left and never tapped, so it is the only one whose conversion says whether retrying a dead
  /// link is worth a surface.
  /// A VALUE on the existing `surface` property — no new event, no new property.
  static const _surfaceSheetReconnect = 'sheet_reconnect';

  /// The sheet's reported name for an attempt, given which re-arm fired it.
  ///
  /// A pure one-liner only because the service itself is unconstructable in a unit test (a real
  /// ApiClient, a real analytics sink, GMS): this is the only way the funnel's most load-bearing
  /// mapping — which `surface` value a re-armed attempt files itself under — is pinnable at all.
  /// A RETURN wins over a reconnect: the person came back to the app themselves, which is the
  /// stronger fact about the attempt, and the two must never blend into a third name.
  @visibleForTesting
  static String sheetSurfaceFor({
    required bool returned,
    bool reconnected = false,
  }) => returned
      ? _surfaceSheetReturn
      : reconnected
      ? _surfaceSheetReconnect
      : _surfaceSheet;

  /// The picker the guard reopens ONCE after Google's add-account flow returned with nothing
  /// chosen. Kept apart from a tapped picker: it is the only button surface nobody asked for, so
  /// it is the only one whose conversion says whether the reopen earns its place.
  /// A VALUE on the existing `surface` property — no new event, no new property.
  static const _surfaceButtonAfterAddAccount = 'button_after_add_account';

  /// The button flow's reported name for an attempt. Pinnable for the same reason as
  /// [sheetSurfaceFor].
  @visibleForTesting
  static String buttonSurfaceFor({required bool reopened}) =>
      reopened ? _surfaceButtonAfterAddAccount : _surfaceButton;

  /// The picker reached by DISMISSING the sheet, kept distinct from a picker
  /// the sheet never contested: it is the only bucket where the user has
  /// already said no once, so it is the only one whose conversion rate says
  /// whether [pickerAfterDismiss] earns its second surface.
  static const _surfaceButtonAfterDismiss = 'button_after_dismiss';

  /// KILL SWITCH for sheet-first: `false` restores the previous behaviour —
  /// the button flow only, on every attempt.
  ///
  /// A `static const` (a BUILD revert, not a server flag) deliberately:
  /// `feature_flags` reach the app through `catalog/app_config.json`
  /// (`appConfigProvider`), which is not on disk on a FIRST launch — and the
  /// first launch is the whole install→login funnel this flow exists for. A
  /// flag that arrives after the surface has opened controls nothing.
  @visibleForTesting
  static const bool sheetFirst = true;

  /// ESCALATE a DISMISSED sheet to the account picker instead of stopping.
  /// `false` restores the guide's default — a dismissal ends the attempt and
  /// the wall's pill is the user's next surface.
  ///
  /// The escalation target is the BUTTON flow (`GetSignInWithGoogleOption`),
  /// deliberately NOT a second `GetGoogleIdOption` pass, even though the
  /// unfiltered pass is what "show all the accounts" sounds like:
  ///  * Both One Tap passes are the SAME rate-limited surface. Google's own
  ///    guidance — "implement your own rate limiting… if a user cancels
  ///    several prompts in a row, the One Tap client will not prompt the user
  ///    for the next 24 hours" — means re-drawing it doubles the cancels per
  ///    attempt, and the 24 h suppression takes AUTOMATIC sign-in with it.
  ///    That is the one thing on this screen that measurably works.
  ///  * The unfiltered pass is a SUPERSET of what was just dismissed. On a
  ///    one-account phone it redraws the identical account — the user reads
  ///    that as the app ignoring them, and it is the 2026-08-11 "two pickers"
  ///    complaint by another route.
  ///  * The button flow is the remedy the SIWG guide names for a dismissal,
  ///    and it alone shows accounts that need re-auth and can ADD an account.
  ///
  /// A BUILD const for the same reason as [sheetFirst].
  @visibleForTesting
  static const bool pickerAfterDismiss = true;

  /// The surface ORDER of Google's SIWG implementation guide, kept pure and
  /// generic so the contract is pinnable without a platform channel.
  ///
  /// One attempt shows ONE Google surface. The button flow follows the sheet
  /// only when the sheet drew nothing at all:
  ///   * credential → done, on the sheet. With a single authorized account
  ///     this is Google's automatic sign-in: the sheet shows briefly and
  ///     nobody taps, so no copy may assume a tap happened.
  ///   * null → nothing was drawable (no accounts on the device, "Sign-in
  ///     prompts" turned off in Google Account settings, or no credential
  ///     after BOTH native steps — authorized-filtered, then unfiltered).
  ///     Nothing was shown, so the button is still the user's first surface.
  ///   * `canceled` → the user DISMISSED the sheet. Under
  ///     [pickerAfterDismiss] this escalates ONCE to the button flow — a
  ///     DIFFERENT surface, not the sheet again; read that const for why the
  ///     unfiltered One Tap pass is the wrong target. It is reported as its
  ///     own surface so the cost (a second dismissal) stays separable from
  ///     the gain, and it is NOT sent to [onSheetUnavailable]: a dismissal is
  ///     a decision, not a failure of the sheet.
  ///   * any other code → the sheet could not COMPLETE (`uiUnavailable`,
  ///     `interrupted`, an Android 14 `TransactionTooLargeException` on
  ///     GMS < 24.40 arriving as `unknownError`, a future code): report it and
  ///     fall through to the button, which none of those failures affect.
  ///     This bucket includes a failure AFTER the user picked an account —
  ///     offline, GMS returns `unknownError` "[28404] Failed to retrieve an ID
  ///     token" (device 2026-09-01) — so the picker CAN follow a sheet the user
  ///     touched. That is deliberate: the user asked to sign in and the sheet
  ///     could not deliver, and no signal distinguishes it from a sheet that
  ///     never drew. Only `canceled` — the user saying no — stops the attempt.
  ///
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
    required bool reopened,
  }) async {
    final attempt = ++_attemptSeq;
    // Clear first: a failure BEFORE any surface opened (unsupported device,
    // config guard) must not report the PREVIOUS attempt's elapsed time or
    // surface, and a fresh attempt never inherits a stale pill subtitle.
    _authClock = null;
    _surface = null;
    // Drops any reading a previous attempt left behind -> a config-guard failure here can never
    // report the last attempt's wait for Google.
    _surfaceClock.endAttempt();
    SignInPhase.exchanging.value = false;
    try {
      // v7: use the singleton. `initialize()` is STARTED in main() but no
      // longer awaited there, so the contract (initialize → credential
      // request) is honoured by awaiting it here instead — off the cold-start
      // path, on the one path that actually needs it. Never throws (see
      // GoogleSignInInit), and it is what put this process's nonce in place.
      await GoogleSignInInit.ready;

      if (!GoogleSignIn.instance.supportsAuthenticate()) {
        return _googleFailure(
          AuthFailureKind.noPlayServices,
          'Google one-tap is not supported on this device. Please update Google Play Services.',
        );
      }

      // Sheet first, but only for the automatic attempt: a tap means the user
      // is already past what the sheet had to offer (see AuthService.signInWith
      // and resolveGoogleCredential for the order and its reasons).
      final useSheet = sheetFirst && auto;
      // The re-arm markers ride the sheet's NAME: an attempt with no sheet is a pill tap, which
      // neither a return nor a reconnect ever is.
      final sheetSurface = sheetSurfaceFor(
        returned: returned,
        reconnected: reconnected,
      );
      final buttonSurface = buttonSurfaceFor(reopened: reopened);
      _analytics.track(
        'login_attempt',
        properties: {
          ..._installProps,
          'provider': 'google',
          'surface': useSheet ? sheetSurface : buttonSurface,
          'auto': auto,
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
        // Google's screen is up. For the people who then leave without a cancel, a success or a
        // failure, this is the one fact that separates "never saw the sheet" from "saw it and left".
        onSurface: (ms) {
          _analytics.track(
            'login_surface_shown',
            properties: {
              ..._installProps,
              'provider': 'google',
              'surface': ?_surface,
              'auto': auto,
              'ms_to_surface': ms,
            },
          );
          SignInPhase.signals.add(SignInSignal.surfaceShown);
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

      // Abandoned by the stall guard while Credential Manager sat on its
      // callback — a newer attempt (or none) owns the session now. Quietly
      // drop the zombie before any side effect.
      if (attempt != _attemptSeq) return const AuthCancelled();

      final idToken = account.authentication.idToken;
      if (idToken == null) {
        return _googleFailure(
          AuthFailureKind.tokenExchangeFailed,
          'Failed to retrieve authentication token. Please try again.',
        );
      }

      // Referral attribution: attach any pending code from the Play Install
      // Referrer. The Worker only honors it on new-user creation, so re-sending
      // on later logins is harmless. Cleared after a successful exchange below.
      final referralCode = _referral?.pendingCode;

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
      final data = await postWithNetworkRetry(
        () => _api.post(
          '/auth/login',
          body: {
            'idToken': idToken,
            // The nonce Google minted this token against (one per process, set
            // at initialize()). The Worker rejects a login whose request nonce
            // and token claim disagree; both absent is still accepted, which is
            // what every build already in the field sends.
            'nonce': ?GoogleSignInInit.nonce,
            'referralCode': ?referralCode,
          },
          requiresAuth: false,
        ),
        onRetry: () {
          exchangeRetried = true;
          BootTrace.mark('signIn: POST /auth/login retry after network error');
        },
      );
      BootTrace.mark('signIn: POST /auth/login done');

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
        userProperties: {
          'display_name': displayName,
          'provider': 'google',
          // The UI language the user chose (not the device locale PostHog
          // stamps as `$locale`) — the axis Arul's 6-locale cohorts split on.
          // Login-time value; refreshed at the next sign-in, like Shubh's.
          'app_language': ?_appLanguage?.call(),
        },
      );
      _crash.setUserId(userId);
      _analytics.track(
        ArulEvents.loginSuccess,
        properties: {
          ..._installProps,
          'provider': 'google',
          // Which Google surface landed it, and how long the attempt took —
          // the pair that says whether sheet-first is working.
          'surface': ?_surface,
          'ms_since_authenticate': ?_msSinceAuthenticate,
          // The same wait the nudges split cancels on, on the outcome that WORKED — without it
          // "Google is slow on this phone" has no denominator.
          'ms_to_surface': ?_msToSurface,
          // Present only when the exchange was saved by the network retry —
          // the field readout for whether the retry earns its keep.
          if (exchangeRetried) 'exchange_retried': true,
        },
      );

      return AuthSuccess(userId: userId);
    } on GoogleSignInException catch (e) {
      // Typed classification, never string-sniffing. The old fallback matched
      // any message containing "cancel" — and Credential Manager phrases REAL
      // failures that way (a token mint dying on a fresh LTE link surfaced as
      // a "cancel", device 2026-08-18), so infra failures became silent
      // pill-bounces with zero telemetry while the funnel bled.
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
            // Not a cancel: nobody touched anything -> no `login_cancelled`, the guard relaunches
            // and files it as `login_failed{kind: surface_stripped}`.
            debugPrint(
              '[ApiAuthService] selector stripped by the OS (surface=$_surface)',
            );
            result = const AuthCancelled(
              outcome: SignInOutcome.selectorStripped,
            );
            break;
          }
          // No error toast (the user may genuinely have closed the sheet) but
          // tracked WITH the plugin's description — see _cancelProperties for
          // why the message text is the dismissal-vs-GMS-failure split.
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
        case AuthFailure(:final kind, :final message):
          _googleFailure(
            kind,
            message,
            gisCode: e.code.name,
            error: e.description,
          );
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
        // The connection hint is earned by data, not guesswork: this bucket is
        // network-dominated in the field (unknownError p50 ~4s/p90 ~39s), and
        // a dead uplink mid-flow reproduces exactly here (device 2026-08-31).
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
