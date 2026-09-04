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
  FutureOr<void> build() {}

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

  /// Re-check cadence once [stallLimit] elapsed while not resumed — wait this much more, look again.
  @visibleForTesting
  Duration stallRecheck = const Duration(seconds: 5);

  /// Seam for the lifecycle read — tests stub it rather than poke the binding's @protected plumbing.
  @visibleForTesting
  AppLifecycleState? Function() lifecycleProbe = () =>
      WidgetsBinding.instance.lifecycleState;

  /// Whether the ONE automatic sign-in of the CURRENT signed-out stretch has been spent.
  ///
  /// Re-armed by [signOut]/[deleteAccount] -> process scope left the post-logout screen with no picker.
  /// A session dying on its own (401) is detected during the startup seed, before the auto-launch.
  /// So no re-arm is needed there — the flag is still false when it matters.
  bool _autoLaunched = false;

  /// Starts a sign-in, or joins the one already running.
  ///
  /// Safe from a button — a tap while a sheet is up gets that sheet's result, never a second sheet.
  /// [auto] passes straight through to the service, which picks the FIRST Google surface.
  /// Not a policy this layer owns.
  Future<AuthResult> signIn(AuthProvider provider, {bool auto = false}) {
    final existing = _inFlight;
    if (existing != null) return existing;
    final raw = ref.read(authServiceProvider).signInWith(provider, auto: auto);
    final started = DateTime.now();
    late final Future<AuthResult> guarded;
    guarded = _guard(raw, started).whenComplete(() {
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
  Future<AuthResult> _guard(Future<AuthResult> raw, DateTime started) async {
    // Start of the current continuous-foreground stretch.
    var sinceForeground = started;
    var wasMidFlow = false;
    while (true) {
      final budget = stallLimit - DateTime.now().difference(sinceForeground);
      if (budget > Duration.zero) {
        try {
          return await raw.timeout(budget);
        } on TimeoutException {
          // Budget spent — evaluate below.
        }
      }
      final lifecycle = lifecycleProbe();
      final maybeMidFlow =
          lifecycle == AppLifecycleState.inactive ||
          lifecycle == AppLifecycleState.paused ||
          lifecycle == AppLifecycleState.hidden;
      if (maybeMidFlow) {
        wasMidFlow = true;
        try {
          return await raw.timeout(stallRecheck);
        } on TimeoutException {
          continue;
        }
      }
      if (wasMidFlow) {
        // Just back from the sheet or background -> a fresh foreground budget.
        // The token exchange is usually still in flight right here.
        wasMidFlow = false;
        sinceForeground = DateTime.now();
        continue;
      }
      // Foreground throughout, spinner up, nothing happening -> the callback is lost.
      ref.read(authServiceProvider).abandonPendingSignIn();
      ref
          .read(analyticsServiceProvider)
          .track(
            'login_failed',
            properties: {'provider': 'google', 'kind': 'stalled'},
          );
      return const AuthFailure(
        message: 'Sign-in is taking too long. Please try again.',
        kind: AuthFailureKind.networkError,
      );
    }
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

  /// The automatic sign-in, fired ONCE per process by whichever screen gets there first.
  ///
  /// The splash the moment it knows there is no stored session, else the sign-in screen's first frame.
  /// Null once that attempt is spent and settled -> the signal to show the retry pill and stay put.
  /// Without it a cancelled sheet re-launches the instant the splash routes, and nobody escapes.
  Future<AuthResult>? autoSignIn(AuthProvider provider) {
    if (_autoLaunched) return _inFlight;
    _autoLaunched = true;
    final attempt = signIn(provider, auto: true);
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
