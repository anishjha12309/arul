import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/analytics/analytics_cohort.dart';
import '../../../core/analytics/analytics_provider.dart';
import '../../../core/api/api_client.dart';
import '../../../core/crash/crash_provider.dart';
import '../../../core/providers/shared_preferences_provider.dart';
import '../../../core/providers/locale_provider.dart';
import '../../../core/update/update_holds.dart';
import '../../referral/providers/referral_providers.dart';
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
  /// One of them appears, hangs and vanishes. That shipped once -> every caller goes through here.
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
  ///
  /// It once slept through its whole budget and read the lifecycle only when that ran out, so a
  /// Home-and-back inside the first 30 s was invisible: the icon relaunch had already stripped
  /// Google's sheet (clearTaskOnLaunch), nothing would ever land, and the pill spun until "taking
  /// too long" — reproduced on device from the sheet, the picker and mid token-mint alike.
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
  ///
  /// Re-armed by [signOut]/[deleteAccount] -> process scope left the post-logout screen with no picker.
  /// A session dying on its own (401) is detected during the startup seed, before the auto-launch.
  /// So no re-arm is needed there — the flag is still false when it matters.
  /// Also re-armed by [noteAppLifecycle] when the user LEFT the wall and came back: a cancel still
  /// never relaunches, but a return after a real away stretch is a fresh visit, not a retry.
  /// And by [noteConnectivity] when the link that killed the last attempt came back.
  bool _autoLaunched = false;

  /// Start of the current away stretch (paused/hidden), cleared on every resume.
  ///
  /// `inactive` is NOT away: that is Google's own surface sitting over us, or a system dialog.
  DateTime? _awaySince;

  /// When the link was last read as DOWN, cleared on every online reading.
  ///
  /// The reading is TRANSPORT-level (connectivity_plus reports the transport, never reachability),
  /// so a Wi-Fi with no internet behind it reads online. That costs nothing here: the transition is
  /// only ever a permission to retry a failure the link already caused, never a claim of anything.
  DateTime? _offlineSince;

  /// When the last attempt SETTLED — success, cancel, failure, or one of the guard's abandons.
  /// Null until an attempt has run at all, which is also what keeps a define-less build inert.
  DateTime? _lastOutcomeAt;

  /// Whether that settled outcome was a NETWORK-class failure — the only one a reconnect may retry.
  ///
  /// `networkError` and the `unknown` bucket, which is where Play services' own token failure lands
  /// (`[28404] Failed to retrieve an ID token`, seen on device with mobile data off) — see
  /// `ApiAuthService.mapGoogleSignInException`, plus the ONE cancel GMS words as a network failure
  /// (`[16] Account reauth failed` from the picker, offline). Every other cancel is a refusal and
  /// never qualifies; `noPlayServices`, `serverError` and `tokenExchangeFailed` survive a reconnect
  /// unchanged.
  bool _lastOutcomeNetworkFailure = false;

  /// Whether THIS failure's one reconnect has already been spent; cleared when the next outcome
  /// settles -> a link that drops and returns twice over one dead attempt still buys one sheet.
  bool _reconnectSpent = false;

  /// How many reconnect re-arms ONE signed-out stretch may spend, across every failure in it.
  ///
  /// A link that flaps — a lift, a train, a phone at the edge of a cell — delivers an
  /// offline->online transition every few seconds, and each one lands on a fresh failure of its
  /// own, so the per-failure allowance alone would let it loop the sheet. Re-armed with the
  /// automatic launch itself, by [signOut] and [deleteAccount].
  static const _reconnectsPerStretch = 2;
  int _reconnectBudget = _reconnectsPerStretch;

  /// Set by [noteAppLifecycle], consumed by the next [autoSignIn] -> that attempt reports itself as
  /// the return sheet (`surface: 'sheet_return'`) instead of a cold-start one.
  bool _returnArmed = false;

  /// The same, for [noteConnectivity] -> `surface: 'sheet_reconnect'`. Analytics only; the surface
  /// ORDER is untouched, so a re-armed attempt is sheet-first exactly like every other automatic one.
  bool _reconnectArmed = false;

  /// One lifecycle transition, from the sign-in wall's observer. Returns true when the caller should
  /// fire the automatic attempt again — the SCREEN stays the single joiner, so the toast and route
  /// handling live in one place.
  ///
  /// The whole rule, for the 52-in-722 who only ever get in on a later return: a person who left the
  /// wall and came back lands on a bare pill today, because the process's one automatic surface was
  /// spent minutes ago. This gives that return its own surface, ONCE, and only when all of these
  /// hold — nothing in flight (the guard owns that case, `stalled_resumed`/`surface_stripped`), still
  /// signed out, an away stretch of at least [returnAwayThreshold] that STARTED after the last
  /// outcome settled, and at least [returnCooldown] since that outcome.
  ///
  /// The away-started-after-the-outcome clause is what keeps "never auto-relaunch on a cancel"
  /// intact: a dismissal followed by a return on the SAME foreground stretch re-arms nothing.
  /// Recents, the launcher icon and a screen lock/unlock all read as paused -> all count as a
  /// return. A rotation or a Google surface reads as inactive -> none of them do.
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
  ///
  /// The case, measured on device with mobile data off: the sheet draws, the account tap dies inside
  /// Play services in 3 s (`[28404] Failed to retrieve an ID token`), the attempt escalates to the
  /// picker, the second pick fails the same way — and when data comes back NOTHING happens. The
  /// person is left in front of a pill nobody told them to tap, holding a phone that now works.
  ///
  /// Google's Credential Manager guidance forbids an automatic retry after a CANCELLATION and only
  /// that ("this error indicates a lack of consent"). A link that was down is not a refusal, so this
  /// one surface is allowed where a re-arm after a cancel never is.
  ///
  /// Conditions, all required: an OFFLINE reading came first (the transition is the event, not the
  /// online reading on its own), the last settled outcome was a network-class failure
  /// ([_lastOutcomeNetworkFailure]), the transition lands after that outcome settled, nothing in
  /// flight (the stall guard owns that case), still signed out, and our own UI is RESUMED — a link
  /// returning behind another app must not push a sheet in front of it.
  ///
  /// Bounded twice over, because the link is the one condition that can repeat by itself: ONE
  /// re-arm per failure ([_reconnectSpent]) and [_reconnectBudget] per signed-out stretch.
  bool noteConnectivity({required bool online}) {
    if (!online) {
      // The FIRST of a run of offline readings owns the stretch; the stream is already `distinct()`.
      _offlineSince ??= now();
      return false;
    }
    final offline = _offlineSince;
    // Cleared whatever the verdict -> at most ONE re-arm per drop, never a second online reading's.
    _offlineSince = null;
    if (offline == null) return false;
    final settled = _lastOutcomeAt;
    if (settled == null) return false;
    if (!_lastOutcomeNetworkFailure) return false;
    if (_reconnectSpent || _reconnectBudget <= 0) return false;
    if (_inFlight != null) return false;
    if (ref.read(authServiceProvider).currentState.isAuthenticated) {
      return false;
    }
    if (!now().isAfter(settled)) return false;
    // Null = no binding at all (a bare unit test) = nothing can have backgrounded us, exactly as
    // the stall guard reads it.
    final lifecycle = lifecycleProbe();
    if (lifecycle != null && lifecycle != AppLifecycleState.resumed) {
      return false;
    }
    _reconnectSpent = true;
    _reconnectBudget--;
    _autoLaunched = false;
    _reconnectArmed = true;
    return true;
  }

  /// Starts a sign-in, or joins the one already running.
  ///
  /// Safe from a button — a tap while a sheet is up gets that sheet's result, never a second sheet.
  /// [auto] passes straight through to the service, which picks the FIRST Google surface.
  /// Not a policy this layer owns.
  /// [returned] is analytics only: it stamps this attempt as the one a RETURN re-armed.
  /// [reconnected] is the same for the one a RECONNECT re-armed; `returned` wins if both are set.
  Future<AuthResult> signIn(
    AuthProvider provider, {
    bool auto = false,
    bool returned = false,
    bool reconnected = false,
  }) {
    final existing = _inFlight;
    if (existing != null) return existing;
    final raw = ref
        .read(authServiceProvider)
        .signInWith(
          provider,
          auto: auto,
          returned: returned,
          reconnected: reconnected,
        );
    final started = DateTime.now();
    // Cleared at the START, not on the settle: [_guard] can return without the classifier below
    // ever running, and a stale `true` would hand the NEXT reconnect a sheet it never earned.
    _lastOutcomeNetworkFailure = false;
    // An update screen over Google's sheet would cancel the attempt -> held until it settles.
    final releaseUpdateHold = UpdateHolds.hold();
    late final Future<AuthResult> guarded;
    guarded = _guard(raw, started, provider, auto, returned, reconnected)
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
          // Identity-checked -> an abandoned attempt's cleanup must not null out its replacement.
          if (identical(_inFlight, guarded)) _inFlight = null;
          releaseUpdateHold();
        });
    _inFlight = guarded;
    return guarded;
  }

  /// Wraps one sign-in attempt with the lost-callback stall guard.
  ///
  /// `authenticate()` has no timeout and Credential Manager can drop its callback outright.
  /// That froze the pill's spinner forever, and a busy pill ignores taps -> sign-in bricked for good.
  /// The guard frees the UI only when THREE hold: budget spent, app RESUMED a full budget, attempt current.
  /// A sheet on top or a backgrounding makes us inactive/paused/hidden -> extend, never abandon.
  /// Abandoning discards the zombie's eventual result, tracks the stall, and shows the retry pill.
  /// The budget clock RESTARTS on every return to the foreground after a mid-flow stretch.
  /// Measuring from the attempt's start abandoned a HEALTHY attempt 20ms before its exchange finished.
  /// The session landed while the screen said "taking too long" — a signed-in user stranded on sign-in.
  /// One pill tap away from a second picker over a live session.
  /// Post-sheet exchange is PROGRESS -> the pathology is an attempt dead through a CONTINUOUS budget.
  ///
  /// RESUMING is not progress on its own. A destroyed `CredentialSelectorActivity` delivers no
  /// result, no cancellation and no exception -> the androidx.credentials continuation never
  /// completes. Returning to a corpse used to buy it a whole fresh budget, so the pill span 30s
  /// more over nothing. [SignInPhase.exchanging] is the discriminator and it was already here:
  /// true means OUR `POST /auth/login` is live and the full budget is exactly right; false means
  /// nothing of ours is running and no Google surface is on top (one would keep us inactive), so
  /// the sheet is gone and only a real back-from-the-sheet outcome can still land — which takes
  /// milliseconds, not seconds. Hence [stallResumeGrace], then abandon.
  ///
  /// The lifecycle is read every [stallTick], not once per budget: the return to the foreground is
  /// the event, and it happens whenever the user comes back, not when a timer says so.
  ///
  /// One `canceled` IS retried: [SignInOutcome.selectorStripped], the one an icon relaunch
  /// manufactures by finishing Google's picker (the service tells it apart by wording). The user
  /// made no choice there. Every other cancellation settles the attempt, as Google's guidance
  /// requires.
  Future<AuthResult> _guard(
    Future<AuthResult> raw,
    DateTime started,
    AuthProvider provider,
    bool auto,
    bool returned,
    bool reconnected,
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
          );
    }

    // The add-account reopen is ONE-SHOT per attempt, like [relaunched].
    var reopened = false;

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
    ///
    /// Add-account: Google's own flow hands the user back with ONE cancellation whether they added
    /// an account, gave up, or were bounced by Google's own "verify it's you" prompt cancelling
    /// itself (seen on an unattended device) -> nothing reopened, and 76% of those people cancel again.
    /// The PICKER comes back once (never the One Tap sheet, which a cancel must not redraw): a
    /// fresh account is then one tap away, and someone who was bounced still has their accounts.
    ///
    /// Play services: "Tap again" can never work on a phone whose Play services is below what
    /// Credential Manager needs, so the failure also asks for GOOGLE'S update dialog. It replaces
    /// nothing and waits for nothing — the failure stands and the pill frees as before; the way
    /// back in is the person's return from the Play Store, which [noteAppLifecycle] or a cold
    /// start already turns into a sign-in.
    Future<({Future<AuthResult> next})?> recover(AuthResult result) async {
      if (result is AuthFailure &&
          result.kind == AuthFailureKind.noPlayServices) {
        unawaited(playServices.ensureAvailable());
        return null;
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
          // This is the regression the guard exists for: an exchange abandoned 20ms before it
          // landed strands a signed-in user on the wall, one tap from a second picker.
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
  ///
  /// `kind` is a VALUE on an event already on the allow-list — `stalled` (never left the
  /// foreground), `stalled_resumed` (came back to a dead sheet), `surface_stripped` (an icon
  /// relaunch finished Google's picker). No new event, no new property.
  void _abandonStalled({required String kind}) {
    ref.read(authServiceProvider).abandonPendingSignIn();
    ref
        .read(analyticsServiceProvider)
        .track(
          'login_failed',
          properties: {'provider': 'google', 'kind': kind},
        );
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
  ///
  /// The splash the moment it knows there is no stored session, else the sign-in screen's first frame.
  /// Null once that attempt is spent and settled -> the signal to show the retry pill and stay put.
  /// Without it a cancelled sheet re-launches the instant the splash routes, and nobody escapes.
  /// [noteAppLifecycle] can re-arm it once for a RETURN and [noteConnectivity] once for a
  /// RECONNECT; those attempts carry the `sheet_return` / `sheet_reconnect` stamp so the funnel can
  /// price each re-arm on its own.
  Future<AuthResult>? autoSignIn(AuthProvider provider) {
    if (_autoLaunched) return _inFlight;
    _autoLaunched = true;
    final returned = _returnArmed;
    final reconnected = _reconnectArmed;
    _returnArmed = false;
    _reconnectArmed = false;
    final attempt = signIn(
      provider,
      auto: true,
      returned: returned,
      reconnected: reconnected,
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

  Future<void> updateDisplayName(String name) =>
      ref.read(authServiceProvider).updateDisplayName(name);

  Future<void> signOut() async {
    await ref.read(authServiceProvider).signOut();
    _autoLaunched = false;
    // A new signed-out stretch -> its own reconnect budget, like its own automatic launch.
    _reconnectBudget = _reconnectsPerStretch;
  }

  /// A session that died on its own mid-process (its refresh token is dead) -> a new signed-out
  /// stretch, exactly as after [signOut]: its own automatic sheet and reconnect budget.
  void sessionEnded() {
    _autoLaunched = false;
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
    _reconnectBudget = _reconnectsPerStretch;
  }
}
