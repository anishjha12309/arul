import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/analytics/analytics_cohort.dart';
import '../../../core/analytics/analytics_provider.dart';
import '../../../core/analytics/journey_stamps.dart';
import '../../../core/api/api_client.dart';
import '../../../core/crash/crash_provider.dart';
import '../../../core/deeplink/install_referrer_service.dart';
import '../../../core/providers/locale_provider.dart';
import '../../../core/providers/shared_preferences_provider.dart';
import '../../../core/update/update_holds.dart';
import '../data/api_auth_service.dart';
import '../data/play_services_resolver.dart';
import '../domain/auth_service.dart';
import '../domain/sign_in_outcome.dart';

part 'auth_providers.g.dart';

@Riverpod(keepAlive: true)
ApiClient apiClient(Ref ref) => ApiClient(
  plainStore: _resolvedPrefs(ref),
  onKeystoreRefused: (error, stack) => ref
      .read(crashReporterProvider)
      .recordError(
        error,
        stack,
        reason: 'keystore refused: session in app-private storage',
      ),
);

/// `main()` overrides [sharedPreferencesProvider] before `runApp`; a container that never ran it
/// (tests) has none, and the session store then keeps today's behaviour with no fallback.
SharedPreferences? _resolvedPrefs(Ref ref) {
  try {
    return ref.read(sharedPreferencesProvider);
  } catch (_) {
    return null;
  }
}

@Riverpod(keepAlive: true)
AuthService authService(Ref ref) => ApiAuthService(
  apiClient: ref.watch(apiClientProvider),
  analytics: ref.watch(analyticsServiceProvider),
  crash: ref.watch(crashReporterProvider),
  installReferrer: ref.watch(installReferrerServiceProvider),
  appLanguage: () => ref.read(localeProvider).languageCode,
  // Resolved in main() before runApp -> settled by the time this provider is first read.
  // Lets the stored-session seed skip the fresh-install keystore wait — see _seedInitialState.
  freshInstall: AnalyticsCohort.isFreshInstall,
);

/// Emits the latest [AuthUserState] — [AsyncLoading] until [ApiAuthService]'s token check fires.
@Riverpod(keepAlive: true)
Stream<AuthUserState> authStateStream(Ref ref) =>
    ref.watch(authServiceProvider).authStateChanges;

/// Sign-in / sign-out actions — consumers read state from [authStateStreamProvider].
@Riverpod(keepAlive: true)
class AuthController extends _$AuthController {
  @override
  FutureOr<void> build() {
    ref.onDispose(() => _disposed = true);
  }

  /// The sign-in currently in flight, already wrapped by [_guard] -> joiners share ONE future.
  /// Identity matters — the tests pin `identical(join, first)`.
  /// The picker is a system Activity -> two overlapping `signInWith` calls put TWO sheets on screen.
  Future<AuthResult>? _inFlight;

  /// How long a sign-in may sit unresolved with OUR OWN UI foregrounded before the guard abandons it.
  ///
  /// Generous on purpose — it exists for the lost-callback pathology, never to clip a live flow.
  /// While inactive/paused/hidden the clock pauses ([_guard] extends) -> reading the list is free.
  /// It adds zero dead air: it only ever fires when nothing is happening at all.
  @visibleForTesting
  Duration stallLimit = const Duration(seconds: 30);

  /// How long a RESUMED attempt with no exchange of ours in flight is given to produce an outcome.
  ///
  /// Short on purpose: a real back-from-the-sheet result lands within milliseconds of the resume,
  /// so anything still silent after this had no callback coming. See [_guard].
  @visibleForTesting
  Duration stallResumeGrace = const Duration(seconds: 2);

  /// How often the guard re-reads the lifecycle while an attempt is pending.
  @visibleForTesting
  Duration stallTick = const Duration(milliseconds: 250);

  /// Seam for the lifecycle read — tests stub it rather than poke the binding's @protected plumbing.
  /// No binding at all (a bare unit test) reads as "resumed": there is no OS to background us.
  @visibleForTesting
  AppLifecycleState? Function() lifecycleProbe = () {
    try {
      return WidgetsBinding.instance.lifecycleState;
    } on FlutterError {
      return null;
    }
  };

  /// How long the app must have been AWAY before a return to the wall re-arms the automatic sheet.
  ///
  /// It separates "left the app and came back" from the app's own flicker: a Google surface, a
  /// permission dialog or a rotation costs a moment, a person going somewhere else costs longer.
  @visibleForTesting
  Duration returnAwayThreshold = const Duration(seconds: 20);

  /// The quiet period after the LAST settled attempt before a return may re-arm.
  ///
  /// Google rate-limits One Tap and suppresses it for 24h after several cancels in a row, which
  /// takes automatic sign-in with it. A re-arm is therefore rare by construction: at most one per
  /// return, and never near the outcome it would be retrying.
  @visibleForTesting
  Duration returnCooldown = const Duration(seconds: 60);

  @visibleForTesting
  PlayServicesResolver playServices = const PlayServicesResolver();

  /// Clock seam for the return rule — tests move time instead of waiting it out.
  /// The stall guard deliberately keeps its own real clock; it is timed by [stallTick], not by this.
  @visibleForTesting
  DateTime Function() now = DateTime.now;

  /// Set when the container goes away -> the guard's tick loop must not outlive it.
  bool _disposed = false;

  /// Whether the ONE automatic sign-in of the CURRENT signed-out stretch has been spent.
  /// Re-armed by [signOut]/[deleteAccount] -> process scope left the post-logout screen with no picker.
  /// Also re-armed by [noteAppLifecycle] when the user LEFT the wall and came back: a cancel still
  /// never relaunches, but a return after a real away stretch is a fresh visit, not a retry.
  /// And by [noteConnectivity] when the link that killed the last attempt came back.
  bool _autoLaunched = false;

  /// Start of the current away stretch (paused/hidden), cleared on every resume.
  ///
  /// `inactive` is NOT away: that is Google's own surface sitting over us, or a system dialog.
  DateTime? _awaySince;

  /// When the link was last read as DOWN, cleared on every online reading.
  DateTime? _offlineSince;

  /// When the last attempt SETTLED — success, cancel, failure, or one of the guard's abandons.
  /// Null until an attempt has run at all, which is also what keeps a define-less build inert.
  DateTime? _lastOutcomeAt;

  /// Whether that settled outcome was a NETWORK-class failure — the only one a reconnect may retry.
  bool _lastOutcomeNetworkFailure = false;

  /// Whether THIS failure's one reconnect has already been spent; cleared when the next outcome
  /// settles -> a link that drops and returns twice over one dead attempt still buys one sheet.
  bool _reconnectSpent = false;

  /// How many reconnect re-arms ONE signed-out stretch may spend, across every failure in it.
  static const _reconnectsPerStretch = 2;
  int _reconnectBudget = _reconnectsPerStretch;

  /// Set by [noteAppLifecycle], consumed by the next [autoSignIn] -> that attempt reports itself as
  /// the return sheet (`surface: 'sheet_return'`) instead of a cold-start one.
  bool _returnArmed = false;

  /// The same, for [noteConnectivity] -> `surface: 'sheet_reconnect'`. Analytics only; the surface
  /// ORDER is untouched, so a re-armed attempt is sheet-first exactly like every other automatic one.
  bool _reconnectArmed = false;

  /// The automatic launch is HELD while the phone has no network: offline, Google's sheet only draws
  /// to fail (docs/auth.md §Failure handling). Released by [noteConnectivity] or a return
  /// ([noteAppLifecycle]); dropped when the person starts an attempt, since the pill is never blocked.
  bool _heldOffline = false;

  /// A PILL TAP made while the phone had no network, parked instead of opening Google: offline the
  /// picker fails in ~2 s with `[16] Account reauth failed`, and people tapped it again and again.
  /// Released like [_heldOffline], but as the BUTTON flow the tap asked for, never the sheet.
  bool _heldTap = false;

  /// An online reading that met the reconnect rule while our UI was behind another app — Settings,
  /// where the data toggle is. Kept for the return instead of dropped; cleared by the next offline
  /// reading or settle.
  bool _reconnectDeferred = false;

  /// True while the wall's automatic sheet is waiting for the network — the wall's wait line.
  bool get autoHeldOffline => _heldOffline;

  /// True while ANY attempt waits for the network — the automatic launch or a parked tap.
  bool get heldForNetwork => _heldOffline || _heldTap;

  /// One lifecycle transition, from the sign-in wall's observer. Returns true when the caller should
  /// fire the automatic attempt again — the SCREEN stays the single joiner, so the toast and route
  /// handling live in one place.
  bool noteAppLifecycle(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        // The FIRST of a paused/hidden run owns the stretch — hidden->paused is one departure.
        _awaySince ??= now();
        return false;
      case AppLifecycleState.resumed:
        final away = _awaySince;
        // Cleared whatever the verdict -> at most ONE re-arm per return, never a second resume's.
        _awaySince = null;
        // A held launch goes on ANY resume — pulling down the shade to turn data on is an
        // inactive->resumed that no away rule would count. [autoSignIn] re-reads the link and simply
        // holds again if it is still down, so a resume can never open a sheet offline.
        if (_heldOffline || _heldTap) return _heldMayGo();
        if (_reconnectDeferred) {
          _reconnectDeferred = false;
          if (_reconnectMayGo()) return _armReconnect();
        }
        final settled = _lastOutcomeAt;
        if (away == null || settled == null) return false;
        if (_inFlight != null) return false;
        if (ref.read(authServiceProvider).currentState.isAuthenticated) {
          return false;
        }
        if (!away.isAfter(settled)) return false;
        final at = now();
        if (at.difference(away) < returnAwayThreshold) return false;
        if (at.difference(settled) < returnCooldown) return false;
        _autoLaunched = false;
        _returnArmed = true;
        return true;
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        return false;
    }
  }

  /// One connectivity reading, from the wall's own listener. Returns true when the caller should
  /// fire the automatic attempt again — same shape and same contract as [noteAppLifecycle], and the
  /// SCREEN still decides nothing.
  bool noteConnectivity({required bool online}) {
    if (!online) {
      // The FIRST of a run of offline readings owns the stretch; the stream is already `distinct()`.
      _offlineSince ??= now();
      _reconnectDeferred = false;
      return false;
    }
    final offline = _offlineSince;
    // Cleared whatever the verdict -> at most ONE re-arm per drop, never a second online reading's.
    _offlineSince = null;
    if (_heldOffline || _heldTap) {
      // No failure behind it and no offline reading needed first: a wall that mounted offline only
      // ever sees the link come UP. Behind another app it stays held for the return to release.
      final lifecycle = lifecycleProbe();
      if (lifecycle != null && lifecycle != AppLifecycleState.resumed) {
        return false;
      }
      return _heldMayGo();
    }
    if (offline == null) return false;
    if (!_reconnectMayGo()) return false;
    // Null = no binding at all (a bare unit test) = nothing can have backgrounded us, exactly as
    // the stall guard reads it.
    final lifecycle = lifecycleProbe();
    if (lifecycle != null && lifecycle != AppLifecycleState.resumed) {
      // Data is usually turned back on from Settings -> the link returns while we are paused, and
      // dropping it here is how the reconnect reached 17 of 494 offline pickers. The return fires it.
      _reconnectDeferred = true;
      return false;
    }
    return _armReconnect();
  }

  /// The reconnect rule minus the transition and the foreground, shared by the live reading and the
  /// return that picks up a deferred one.
  bool _reconnectMayGo() {
    final settled = _lastOutcomeAt;
    if (settled == null) return false;
    if (!_lastOutcomeNetworkFailure) return false;
    if (_reconnectSpent || _reconnectBudget <= 0) return false;
    if (_inFlight != null) return false;
    if (ref.read(authServiceProvider).currentState.isAuthenticated) {
      return false;
    }
    return now().isAfter(settled);
  }

  bool _armReconnect() {
    _reconnectSpent = true;
    _reconnectBudget--;
    _autoLaunched = false;
    _reconnectArmed = true;
    return true;
  }

  /// Whether the held launch may fire now. It spends none of the reconnect budget: it is the
  /// stretch's first automatic attempt, delayed, not a retry.
  bool _heldMayGo() =>
      _inFlight == null &&
      !ref.read(authServiceProvider).currentState.isAuthenticated;

  /// Starts a sign-in, or joins the one already running.
  /// Safe from a button — a tap while a sheet is up gets that sheet's result, never a second sheet.
  Future<AuthResult> signIn(
    AuthProvider provider, {
    bool auto = false,
    bool returned = false,
    bool reconnected = false,
    bool afterOffline = false,
  }) {
    final existing = _inFlight;
    if (existing != null) return existing;
    // An attempt of any kind ends the wait: a tap is the person taking over, and the held launch
    // itself arrives here from [autoSignIn].
    _heldOffline = false;
    _heldTap = false;
    final raw = ref
        .read(authServiceProvider)
        .signInWith(
          provider,
          auto: auto,
          returned: returned,
          reconnected: reconnected,
          afterOffline: afterOffline,
        );
    final started = DateTime.now();
    // Cleared at the START, not on the settle: [_guard] can return without the classifier below
    // ever running, and a stale `true` would hand the NEXT reconnect a sheet it never earned.
    _lastOutcomeNetworkFailure = false;
    final releaseUpdateHold = UpdateHolds.hold();
    late final Future<AuthResult> guarded;
    guarded = _guard(raw, started, provider, auto, returned, reconnected, afterOffline)
        .then((result) {
          // What the reconnect rule is allowed to retry, decided where the outcome is still typed.
          _lastOutcomeNetworkFailure =
              (result is AuthFailure &&
                  (result.kind == AuthFailureKind.networkError ||
                      result.kind == AuthFailureKind.unknown)) ||
              // The PICKER reports an offline pick as a CANCEL — `[16] Account reauth failed`
              // (device, mobile data off) — so the one cancel worded that way counts too. A person's
              // refusal is never spelled like this, and the rule still needs the link to have dropped
              // first, so an account that genuinely needs re-auth cannot loop the sheet.
              (result is AuthCancelled &&
                  result.outcome == SignInOutcome.reauthFailed);
          return result;
        })
        .whenComplete(() {
          // The return rule measures its cooldown from here -> every settle counts, abandons included.
          _lastOutcomeAt = now();
          // A fresh outcome, so the reconnect rule's one-per-failure allowance is fresh too.
          _reconnectSpent = false;
          _reconnectDeferred = false;
          // Identity-checked -> an abandoned attempt's cleanup must not null out its replacement.
          if (identical(_inFlight, guarded)) _inFlight = null;
          releaseUpdateHold();
        });
    _inFlight = guarded;
    return guarded;
  }

  /// Wraps one sign-in attempt with the lost-callback stall guard.
  Future<AuthResult> _guard(
    Future<AuthResult> raw,
    DateTime started,
    AuthProvider provider,
    bool auto,
    bool returned,
    bool reconnected,
    bool afterOffline,
  ) async {
    var sinceForeground = started;
    var wasMidFlow = false;
    // The relaunch is ONE-SHOT per attempt -> a second lost sheet cannot loop it.
    var relaunched = false;

    bool midFlow(AppLifecycleState? state) =>
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden;

    bool stripped(AuthResult result) =>
        !relaunched &&
        result is AuthCancelled &&
        result.outcome == SignInOutcome.selectorStripped;

    // A LOST callback reruns the attempt as it was: nobody answered the surface. A STRIPPED picker
    // reopens the PICKER only — the sheet in front of it was already dismissed, and a redrawn One
    // Tap sheet counts toward Google's 24 h cancel suppression.
    Future<AuthResult> relaunch(String kind, {bool pickerOnly = false}) {
      relaunched = true;
      _abandonStalled(kind: kind);
      sinceForeground = DateTime.now();
      wasMidFlow = false;
      return ref
          .read(authServiceProvider)
          .signInWith(
            provider,
            auto: auto && !pickerOnly,
            returned: returned,
            reconnected: reconnected,
            afterOffline: afterOffline,
          );
    }

    // The add-account reopen is ONE-SHOT per attempt, like [relaunched].
    var reopened = false;
    // So is the re-ask after a cold Play services timed the picker out: the next query answers
    // in ~0.1 s once it is warm, where the person otherwise read "couldn't sign in".
    var requeried = false;

    // A result lands in onActivityResult, a beat before our own surface is resumed again.
    Future<bool> foregroundWithinGrace() async {
      final deadline = DateTime.now().add(stallResumeGrace);
      while (midFlow(lifecycleProbe())) {
        if (_disposed || !DateTime.now().isBefore(deadline)) return false;
        await Future<void>.delayed(stallTick);
      }
      return !_disposed;
    }

    /// The attempt that replaces a settled one, or null when [result] stands.
    Future<({Future<AuthResult> next})?> recover(AuthResult result) async {
      if (result is AuthFailure &&
          result.kind == AuthFailureKind.noPlayServices) {
        unawaited(playServices.ensureAvailable());
        return null;
      }
      if (!requeried && result is AuthFailure && result.providerTimedOut) {
        requeried = true;
        if (!await foregroundWithinGrace()) return null;
        sinceForeground = DateTime.now();
        wasMidFlow = false;
        return (
          next: ref
              .read(authServiceProvider)
              .signInWith(provider, afterTimeout: true),
        );
      }
      if (!reopened &&
          result is AuthCancelled &&
          result.outcome == SignInOutcome.addAccountAbandoned) {
        reopened = true;
        if (!await foregroundWithinGrace()) return null;
        sinceForeground = DateTime.now();
        wasMidFlow = false;
        return (
          next: ref
              .read(authServiceProvider)
              .signInWith(provider, reopened: true),
        );
      }
      return null;
    }

    while (true) {
      AuthResult? settled;
      try {
        settled = await raw.timeout(stallTick);
      } on TimeoutException {
        settled = null;
      }
      if (settled != null) {
        if (stripped(settled)) {
          raw = relaunch('surface_stripped', pickerOnly: true);
          continue;
        }
        final recovery = await recover(settled);
        if (recovery != null) {
          raw = recovery.next;
          continue;
        }
        return settled;
      }
      // The container is gone (tests, a hot restart) -> nothing to guard for.
      if (_disposed) return const AuthCancelled();

      final now = DateTime.now();
      if (midFlow(lifecycleProbe())) {
        // A Google surface is on top or the app is backgrounded -> the clock pauses.
        wasMidFlow = true;
        sinceForeground = now;
        continue;
      }
      if (wasMidFlow) {
        wasMidFlow = false;
        if (SignInPhase.exchanging.value) {
          // Our own `POST /auth/login` is live -> a fresh foreground budget, exactly as before.
          sinceForeground = now;
          continue;
        }
        // Resumed with nothing of ours in flight. Give a real outcome its few milliseconds.
        AuthResult? late;
        try {
          late = await raw.timeout(stallResumeGrace);
        } on TimeoutException {
          late = null;
        }
        if (late != null) {
          if (stripped(late)) {
            raw = relaunch('surface_stripped', pickerOnly: true);
            continue;
          }
          final recovery = await recover(late);
          if (recovery != null) {
            raw = recovery.next;
            continue;
          }
          return late;
        }
        if (SignInPhase.exchanging.value) {
          // The credential landed inside the grace and the exchange is live now.
          sinceForeground = DateTime.now();
          continue;
        }
        if (midFlow(lifecycleProbe())) {
          // A surface came back on top during the grace — returning by RECENTS does exactly this.
          // That is mid-flow again, not a corpse: extend as always.
          wasMidFlow = true;
          continue;
        }
        if (!relaunched) {
          // The one exemption to "one visible Google surface per attempt": the first surface is
          // provably gone and delivered nothing, so this replaces it rather than adding to it.
          raw = relaunch('stalled_resumed');
          continue;
        }
        _abandonStalled(kind: 'stalled_resumed');
        return const AuthFailure(
          message: 'Sign-in is taking too long. Please try again.',
          kind: AuthFailureKind.networkError,
        );
      }
      if (now.difference(sinceForeground) >= stallLimit) {
        // Foreground throughout, spinner up, nothing happening -> the callback is lost.
        _abandonStalled(kind: 'stalled');
        return const AuthFailure(
          message: 'Sign-in is taking too long. Please try again.',
          kind: AuthFailureKind.networkError,
        );
      }
    }
  }

  /// Discards the zombie's eventual result and counts the stall.
  void _abandonStalled({required String kind}) {
    final auth = ref.read(authServiceProvider);
    // Read BEFORE abandoning: the context belongs to the attempt that stalled.
    final context = auth.attemptAnalytics;
    auth.abandonPendingSignIn();
    ref
        .read(analyticsServiceProvider)
        .track(
          'login_failed',
          properties: {...context, 'provider': 'google', 'kind': kind},
        );
    JourneyStamps.noteSignInOutcome('failed:$kind');
  }

  /// A failure from the auto-launched attempt, held until a screen can show it.
  ///
  /// The splash fires [autoSignIn] fire-and-forget -> a FAST failure settles before it has routed.
  /// The sign-in screen then joins a spent attempt whose result is gone — a silent bounce, forbidden.
  /// The screen collects this on its first frame; consumed on read so it can never re-toast.
  AuthFailure? _pendingAutoFailure;

  AuthFailure? takePendingAutoFailure() {
    final failure = _pendingAutoFailure;
    _pendingAutoFailure = null;
    return failure;
  }

  /// The automatic sign-in, fired ONCE per signed-out stretch by whichever screen gets there first.
  /// The splash the moment it knows there is no stored session, else the sign-in screen's first frame.
  /// Null once that attempt is spent and settled -> the signal to show the retry pill and stay put.
  /// Without it a cancelled sheet re-launches the instant the splash routes, and nobody escapes.
  /// [offline] = the caller KNOWS there is no network: the launch is HELD ([autoHeldOffline]) and this
  /// returns null without spending it. An unknown reading is online — a slow probe must never cost a
  /// phone with a network its sheet.
  Future<AuthResult>? autoSignIn(
    AuthProvider provider, {
    bool offline = false,
  }) {
    if (_heldTap) {
      if (offline) return null;
      // The parked tap asked for the picker -> the picker, never a sheet the person dismissed.
      return signIn(provider, afterOffline: true);
    }
    if (_autoLaunched) return _inFlight;
    if (offline) {
      _heldOffline = true;
      return null;
    }
    _autoLaunched = true;
    final afterOffline = _heldOffline;
    final returned = _returnArmed;
    final reconnected = _reconnectArmed;
    _returnArmed = false;
    _reconnectArmed = false;
    final attempt = signIn(
      provider,
      auto: true,
      returned: returned,
      reconnected: reconnected,
      afterOffline: afterOffline,
    );
    // Record a failure in case it settles before any screen joins; a joiner clears it after toasting.
    // The service never throws — every path returns a result -> no error continuation.
    unawaited(
      attempt.then((result) {
        if (result is AuthFailure) _pendingAutoFailure = result;
      }),
    );
    return attempt;
  }

  /// Parks a pill tap made while the phone KNOWS it has no network; the link or a return releases
  /// it through [autoSignIn]. A launch already held keeps its sheet: it is the stretch's first
  /// attempt and was never drawn.
  void holdTapForNetwork() {
    if (_inFlight != null || _heldOffline) return;
    _heldTap = true;
  }

  Future<void> updateDisplayName(String name) =>
      ref.read(authServiceProvider).updateDisplayName(name);

  Future<void> signOut() async {
    await ref.read(authServiceProvider).signOut();
    _autoLaunched = false;
    _heldOffline = false;
    _heldTap = false;
    _reconnectDeferred = false;
    // A new signed-out stretch -> its own reconnect budget, like its own automatic launch.
    _reconnectBudget = _reconnectsPerStretch;
  }

  /// A session that died on its own mid-process (its refresh token is dead) -> a new signed-out
  /// stretch, exactly as after [signOut]: its own automatic sheet and reconnect budget.
  void sessionEnded() {
    _autoLaunched = false;
    _heldOffline = false;
    _heldTap = false;
    _reconnectDeferred = false;
    _reconnectBudget = _reconnectsPerStretch;
  }

  /// Permanently deletes the account server-side and clears the session.
  /// Throws on failure, account intact, so the UI can surface the error.
  ///
  /// A failed delete leaves the user signed in -> the re-arm is AFTER the await, never before.
  /// Otherwise it hands a picker to a session that is still perfectly alive.
  Future<void> deleteAccount() async {
    await ref.read(authServiceProvider).deleteAccount();
    _autoLaunched = false;
    _heldOffline = false;
    _heldTap = false;
    _reconnectDeferred = false;
    _reconnectBudget = _reconnectsPerStretch;
  }
}
