import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/analytics/analytics_cohort.dart';
import '../../../core/analytics/analytics_provider.dart';
import '../../../core/api/api_client.dart';
import '../../../core/crash/crash_provider.dart';
import '../../../core/providers/locale_provider.dart';
import '../../referral/providers/referral_providers.dart';
import '../data/api_auth_service.dart';
import '../domain/auth_service.dart';
import '../domain/sign_in_outcome.dart';

part 'auth_providers.g.dart';

@Riverpod(keepAlive: true)
ApiClient apiClient(Ref ref) => ApiClient();

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
  bool _autoLaunched = false;

  /// Start of the current away stretch (paused/hidden), cleared on every resume.
  ///
  /// `inactive` is NOT away: that is Google's own surface sitting over us, or a system dialog.
  DateTime? _awaySince;

  /// When the last attempt SETTLED — success, cancel, failure, or one of the guard's abandons.
  /// Null until an attempt has run at all, which is also what keeps a define-less build inert.
  DateTime? _lastOutcomeAt;

  /// Set by [noteAppLifecycle], consumed by the next [autoSignIn] -> that attempt reports itself as
  /// the return sheet (`surface: 'sheet_return'`) instead of a cold-start one.
  bool _returnArmed = false;

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

  /// Starts a sign-in, or joins the one already running.
  ///
  /// Safe from a button — a tap while a sheet is up gets that sheet's result, never a second sheet.
  /// [auto] passes straight through to the service, which picks the FIRST Google surface.
  /// Not a policy this layer owns.
  /// [returned] is analytics only: it stamps this attempt as the one a RETURN re-armed.
  Future<AuthResult> signIn(
    AuthProvider provider, {
    bool auto = false,
    bool returned = false,
  }) {
    final existing = _inFlight;
    if (existing != null) return existing;
    final raw = ref
        .read(authServiceProvider)
        .signInWith(provider, auto: auto, returned: returned);
    final started = DateTime.now();
    late final Future<AuthResult> guarded;
    guarded = _guard(raw, started, provider, auto, returned).whenComplete(() {
      // The return rule measures its cooldown from here -> every settle counts, abandons included.
      _lastOutcomeAt = now();
      // Identity-checked -> an abandoned attempt's cleanup must not null out its replacement.
      if (identical(_inFlight, guarded)) _inFlight = null;
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
  ) async {
    // Start of the current continuous-foreground stretch.
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

    Future<AuthResult> relaunch(String kind) {
      relaunched = true;
      _abandonStalled(kind: kind);
      sinceForeground = DateTime.now();
      wasMidFlow = false;
      return ref
          .read(authServiceProvider)
          .signInWith(provider, auto: auto, returned: returned);
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
          raw = relaunch('surface_stripped');
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
            raw = relaunch('surface_stripped');
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

  /// Returns the not-yet-surfaced auto-attempt failure, if any, and clears it.
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
  /// [noteAppLifecycle] can re-arm it once for a RETURN; that attempt carries the `sheet_return`
  /// stamp so the funnel can price the return surface on its own.
  Future<AuthResult>? autoSignIn(AuthProvider provider) {
    if (_autoLaunched) return _inFlight;
    _autoLaunched = true;
    final returned = _returnArmed;
    _returnArmed = false;
    final attempt = signIn(provider, auto: true, returned: returned);
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
  }

  /// Permanently deletes the account server-side and clears the session.
  /// Throws on failure, account intact, so the UI can surface the error.
  ///
  /// A failed delete leaves the user signed in -> the re-arm is AFTER the await, never before.
  /// Otherwise it hands a picker to a session that is still perfectly alive.
  Future<void> deleteAccount() async {
    await ref.read(authServiceProvider).deleteAccount();
    _autoLaunched = false;
  }
}
