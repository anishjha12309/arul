import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:arul/core/api/api_client.dart';
import 'package:arul/core/auth/google_sign_in_init.dart';
import 'package:arul/features/auth/data/api_auth_service.dart';
import 'package:arul/features/auth/data/play_services_resolver.dart';
import 'package:arul/features/auth/domain/auth_service.dart';
import 'package:arul/features/auth/domain/sign_in_outcome.dart';
import 'package:arul/features/auth/providers/auth_providers.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;

/// Records every `signInWith` call and settles them by hand -> "was a second picker opened?" becomes a call count.
class _FakeAuthService implements AuthService {
  final List<Completer<AuthResult>> attempts = [];
  int signOutCount = 0;
  int abandonCount = 0;

  final List<bool> autoFlags = [];

  /// The `returned` flag each attempt carried -> "did the RETURN marker reach the service?".
  final List<bool> returnedFlags = [];

  /// The `reconnected` flag each attempt carried -> the same for the RECONNECT marker.
  final List<bool> reconnectedFlags = [];

  /// The `reopened` flag each attempt carried -> "was this the picker put back after add-account?".
  final List<bool> reopenedFlags = [];

  /// Flipped by the tests that need a live session (neither re-arm may fire over one).
  bool authed = false;

  @override
  Future<AuthResult> signInWith(
    AuthProvider provider, {
    bool auto = false,
    bool returned = false,
    bool reconnected = false,
    bool reopened = false,
  }) {
    final completer = Completer<AuthResult>();
    attempts.add(completer);
    autoFlags.add(auto);
    returnedFlags.add(returned);
    reconnectedFlags.add(reconnected);
    reopenedFlags.add(reopened);
    return completer.future;
  }

  @override
  void abandonPendingSignIn() => abandonCount++;

  void settleLast(AuthResult result) => attempts.last.complete(result);

  @override
  Future<void> signOut() async => signOutCount++;

  @override
  Future<void> deleteAccount() async {}

  @override
  Stream<AuthUserState> get authStateChanges => const Stream.empty();

  @override
  AuthUserState get currentState => authed
      ? AuthUserState.authenticated(userId: 'u1')
      : AuthUserState.unauthenticated();

  @override
  Future<void> get initialized async {}

  @override
  Future<void> updateDisplayName(String name) async {}
}

/// Answers for the native Play services repair -> "was Google's dialog asked for?" is a call count.
class _FakeResolver implements PlayServicesResolver {
  _FakeResolver(PlayServicesFix fix) : _answer = Future.value(fix);

  /// A repair whose Task never settles — the dialog left open, or a callback that never comes.
  _FakeResolver.hanging() : _answer = Completer<PlayServicesFix>().future;

  final Future<PlayServicesFix> _answer;
  int calls = 0;

  @override
  Future<PlayServicesFix> ensureAvailable() {
    calls++;
    return _answer;
  }
}

// ─── Domain model tests ───────────────────────────────────────────────────────

void main() {
  // Google's account picker is a system Activity -> two overlapping attempts put two sheets on screen.
  // Zero attempts strand the user on a dead screen -> both shipped once -> these pin the guard from either side.
  group('AuthController auto sign-in', () {
    late _FakeAuthService auth;
    late AuthController controller;

    setUp(() {
      auth = _FakeAuthService();
      final container = ProviderContainer(
        overrides: [authServiceProvider.overrideWithValue(auth)],
      );
      addTearDown(container.dispose);
      controller = container.read(authControllerProvider.notifier);
    });

    test('a second caller JOINS the in-flight attempt, never opens a 2nd '
        'picker', () async {
      final first = controller.autoSignIn(AuthProvider.google);
      final second = controller.autoSignIn(AuthProvider.google);

      expect(auth.attempts, hasLength(1), reason: 'one picker only');
      expect(identical(first, second), isTrue);

      auth.settleLast(const AuthSuccess(userId: 'u1'));
      await first;
    });

    test('the pill joins a sheet that is already up', () async {
      final auto = controller.autoSignIn(AuthProvider.google);
      final tap = controller.signIn(AuthProvider.google);

      expect(auth.attempts, hasLength(1));
      expect(identical(auto, tap), isTrue);

      auth.settleLast(const AuthCancelled());
      await tap;
    });

    test('a spent, settled auto-launch returns null so a cancelled sheet is '
        'not relaunched', () async {
      final first = controller.autoSignIn(AuthProvider.google)!;
      auth.settleLast(const AuthCancelled());
      await first;

      expect(controller.autoSignIn(AuthProvider.google), isNull);
      expect(auth.attempts, hasLength(1));
    });

    test('the pill still works after the auto-launch is spent', () async {
      final first = controller.autoSignIn(AuthProvider.google)!;
      auth.settleLast(const AuthCancelled());
      await first;

      final retry = controller.signIn(AuthProvider.google);
      expect(
        auth.attempts,
        hasLength(2),
        reason: 'manual retry is never gated',
      );
      auth.settleLast(const AuthSuccess(userId: 'u1'));
      await retry;
    });

    test('a failure that settles with NO joiner is held, and consumed on '
        'read', () async {
      // The splash fires the auto attempt fire-and-forget -> a fast failure settles before the sign-in screen mounts.
      final first = controller.autoSignIn(AuthProvider.google)!;
      auth.settleLast(
        const AuthFailure(
          message: 'Google one-tap is not supported on this device.',
          kind: AuthFailureKind.noPlayServices,
        ),
      );
      await first;

      final missed = controller.takePendingAutoFailure();
      expect(missed, isNotNull, reason: 'a pre-route failure must not vanish');
      expect(missed!.kind, AuthFailureKind.noPlayServices);
      expect(
        controller.takePendingAutoFailure(),
        isNull,
        reason: 'consumed on read — a later mount must not re-toast it',
      );
    });

    test(
      'a cancelled auto attempt is never held — cancel stays quiet',
      () async {
        final first = controller.autoSignIn(AuthProvider.google)!;
        auth.settleLast(const AuthCancelled());
        await first;

        expect(controller.takePendingAutoFailure(), isNull);
      },
    );

    test('signing out RE-ARMS the auto-launch', () async {
      final first = controller.autoSignIn(AuthProvider.google)!;
      auth.settleLast(const AuthSuccess(userId: 'u1'));
      await first;
      expect(controller.autoSignIn(AuthProvider.google), isNull);

      await controller.signOut();

      expect(
        controller.autoSignIn(AuthProvider.google),
        isNotNull,
        reason: 'logging out must bring the picker back',
      );
      expect(auth.attempts, hasLength(2));
    });

    test('deleting the account RE-ARMS the auto-launch', () async {
      final first = controller.autoSignIn(AuthProvider.google)!;
      auth.settleLast(const AuthSuccess(userId: 'u1'));
      await first;

      await controller.deleteAccount();

      expect(controller.autoSignIn(AuthProvider.google), isNotNull);
    });
  });

  // 52 of build 74's 722 logins landed on a LATER return, and 28 of 157 lost attempters came back
  // more than ten minutes after failing — to a bare pill, because the process's one automatic
  // surface was spent minutes ago. The re-arm gives that return its own sheet, ONCE. These pin the
  // fire, and harder, every case that must NOT: a cancel's own foreground stretch, an attempt in
  // flight, a second resume with no away stretch, a live session, and Google's rate-limit window.
  group('AuthController return re-arm', () {
    late _FakeAuthService auth;
    late AuthController controller;
    final t0 = DateTime(2026, 9, 15, 10);
    late DateTime clock;

    setUp(() {
      auth = _FakeAuthService();
      final container = ProviderContainer(
        overrides: [authServiceProvider.overrideWithValue(auth)],
      );
      addTearDown(container.dispose);
      clock = t0;
      controller = container.read(authControllerProvider.notifier)
        // Parenthesised: a bare `() => clock` swallows the cascade below into its body.
        ..now = (() => clock)
        ..stallTick = const Duration(milliseconds: 10)
        // Paused throughout -> the stall guard never abandons an attempt a test parks in flight.
        // The return rule reads `now`, never the probe, so this constrains nothing it does.
        ..lifecycleProbe = (() => AppLifecycleState.paused);
    });

    /// The cold-start attempt, cancelled at [t0] — every return scenario starts from one.
    Future<void> coldStartCancelled() async {
      final first = controller.autoSignIn(AuthProvider.google)!;
      auth.settleLast(const AuthCancelled());
      await first;
    }

    test(
      'a cold start is ONE attempt and is never marked as a return',
      () async {
        final splash = controller.autoSignIn(AuthProvider.google);
        final firstFrame = controller.autoSignIn(AuthProvider.google);

        expect(identical(splash, firstFrame), isTrue);
        expect(auth.attempts, hasLength(1));
        expect(auth.returnedFlags, [false]);

        auth.settleLast(const AuthCancelled());
        await splash!;
      },
    );

    test('a return inside the cooldown re-arms nothing; one past it fires '
        'exactly ONE attempt, marked as a return', () async {
      await coldStartCancelled();

      clock = t0.add(const Duration(seconds: 5));
      expect(controller.noteAppLifecycle(AppLifecycleState.paused), isFalse);
      clock = t0.add(const Duration(seconds: 40));
      expect(
        controller.noteAppLifecycle(AppLifecycleState.resumed),
        isFalse,
        reason: '35s away is enough, 40s since the cancel is not',
      );
      expect(auth.attempts, hasLength(1));

      clock = t0.add(const Duration(seconds: 45));
      controller.noteAppLifecycle(AppLifecycleState.paused);
      clock = t0.add(const Duration(seconds: 70));
      expect(controller.noteAppLifecycle(AppLifecycleState.resumed), isTrue);

      final again = controller.autoSignIn(AuthProvider.google);
      expect(again, isNotNull, reason: 'the re-arm must un-spend the launch');
      expect(auth.attempts, hasLength(2));
      expect(auth.returnedFlags, [false, true]);
      expect(auth.autoFlags, [
        true,
        true,
      ], reason: 'sheet-first, exactly like the cold-start attempt');

      auth.settleLast(const AuthCancelled());
      await again!;
    });

    test('an away stretch under the threshold is not a return', () async {
      await coldStartCancelled();

      clock = t0.add(const Duration(seconds: 90));
      controller.noteAppLifecycle(AppLifecycleState.paused);
      clock = t0.add(const Duration(seconds: 100));
      expect(
        controller.noteAppLifecycle(AppLifecycleState.resumed),
        isFalse,
        reason: '10s away — the cooldown is long past, the departure was not',
      );
      expect(controller.autoSignIn(AuthProvider.google), isNull);
      expect(auth.attempts, hasLength(1));
    });

    test(
      'inactive is NOT away — a Google surface over us is not a return',
      () async {
        await coldStartCancelled();

        clock = t0.add(const Duration(seconds: 100));
        controller.noteAppLifecycle(AppLifecycleState.inactive);
        clock = t0.add(const Duration(seconds: 200));
        expect(controller.noteAppLifecycle(AppLifecycleState.resumed), isFalse);
        expect(auth.attempts, hasLength(1));
      },
    );

    test('a return while an attempt is IN FLIGHT joins it, never a second '
        'surface', () async {
      await coldStartCancelled();

      clock = t0.add(const Duration(seconds: 120));
      final pill = controller.signIn(AuthProvider.google);
      controller.noteAppLifecycle(AppLifecycleState.paused);
      clock = t0.add(const Duration(seconds: 200));
      expect(
        controller.noteAppLifecycle(AppLifecycleState.resumed),
        isFalse,
        reason: 'the stall guard owns an attempt in flight, not this rule',
      );
      expect(auth.attempts, hasLength(2));

      auth.settleLast(const AuthCancelled());
      await pill;
    });

    test('ONE re-arm per return — a second resume with no away stretch buys '
        'nothing', () async {
      await coldStartCancelled();

      clock = t0.add(const Duration(seconds: 100));
      controller.noteAppLifecycle(AppLifecycleState.paused);
      clock = t0.add(const Duration(seconds: 130));
      expect(controller.noteAppLifecycle(AppLifecycleState.resumed), isTrue);
      expect(
        controller.noteAppLifecycle(AppLifecycleState.resumed),
        isFalse,
        reason: 'the away stretch is spent the moment it is read',
      );

      final again = controller.autoSignIn(AuthProvider.google)!;
      expect(auth.attempts, hasLength(2));
      auth.settleLast(const AuthCancelled());
      await again;

      clock = t0.add(const Duration(seconds: 300));
      expect(
        controller.noteAppLifecycle(AppLifecycleState.resumed),
        isFalse,
        reason: 'nothing to return from — the app never left',
      );
      expect(auth.attempts, hasLength(2));
    });

    test('a cancel that lands while the app is away does not make that same '
        'return a relaunch', () async {
      final first = controller.autoSignIn(AuthProvider.google)!;
      controller.noteAppLifecycle(AppLifecycleState.paused);
      clock = t0.add(const Duration(seconds: 120));
      auth.settleLast(const AuthCancelled());
      await first;

      expect(
        controller.noteAppLifecycle(AppLifecycleState.resumed),
        isFalse,
        reason:
            'the stretch began BEFORE the cancel — this return IS the cancel',
      );
      expect(auth.attempts, hasLength(1));
    });

    test('a signed-in user is never handed a sheet on return', () async {
      await coldStartCancelled();
      auth.authed = true;

      clock = t0.add(const Duration(seconds: 100));
      controller.noteAppLifecycle(AppLifecycleState.paused);
      clock = t0.add(const Duration(seconds: 130));
      expect(controller.noteAppLifecycle(AppLifecycleState.resumed), isFalse);
      expect(auth.attempts, hasLength(1));
    });

    test('a build with no attempt behind it (define-less, nothing ever fired) '
        'never re-arms', () async {
      clock = t0.add(const Duration(seconds: 100));
      controller.noteAppLifecycle(AppLifecycleState.paused);
      clock = t0.add(const Duration(seconds: 300));
      expect(controller.noteAppLifecycle(AppLifecycleState.resumed), isFalse);
      expect(auth.attempts, isEmpty);
    });
  });

  // With mobile data off the sheet draws, the account tap dies inside Play services in 3s
  // (`[28404] Failed to retrieve an ID token`), the picker follows and dies the same way — and when
  // data comes back the wall sits there. Google's guide forbids an automatic retry after a
  // CANCELLATION and only that, so the link coming back earns one more sheet. These pin which
  // outcomes qualify and that a flapping link can never loop it.
  group('AuthController reconnect re-arm', () {
    late _FakeAuthService auth;
    late AuthController controller;
    final t0 = DateTime(2026, 9, 15, 10);
    late DateTime clock;

    setUp(() {
      auth = _FakeAuthService();
      final container = ProviderContainer(
        overrides: [authServiceProvider.overrideWithValue(auth)],
      );
      addTearDown(container.dispose);
      clock = t0;
      controller = container.read(authControllerProvider.notifier)
        // Parenthesised: a bare `() => clock` swallows the cascade below into its body.
        ..now = (() => clock)
        ..stallTick = const Duration(milliseconds: 10)
        // The rule requires OUR UI to be foregrounded -> a link returning behind another app must
        // not put a sheet in front of it. The stall guard's own budget is 30s of real time, which
        // no test here spends.
        ..lifecycleProbe = (() => AppLifecycleState.resumed)
        // A `noPlayServices` failure asks the native side for Google's dialog; there is none here.
        ..playServices = _FakeResolver(PlayServicesFix.unresolved);
    });

    /// The cold-start attempt, dead the way a missing link kills one, settled at [t0].
    Future<void> coldStartFailed([
      AuthFailureKind kind = AuthFailureKind.unknown,
    ]) async {
      final first = controller.autoSignIn(AuthProvider.google)!;
      auth.settleLast(
        AuthFailure(
          message: 'Sign-in didn\'t complete. Check your internet connection…',
          kind: kind,
        ),
      );
      await first;
    }

    /// An offline reading followed by an online one, a few seconds apart.
    bool reconnect({int at = 20}) {
      clock = t0.add(Duration(seconds: at - 10));
      expect(controller.noteConnectivity(online: false), isFalse);
      clock = t0.add(Duration(seconds: at));
      return controller.noteConnectivity(online: true);
    }

    for (final kind in const [
      AuthFailureKind.unknown,
      AuthFailureKind.networkError,
    ]) {
      test('the link coming back after a ${kind.name} failure fires exactly '
          'ONE attempt, marked as a reconnect', () async {
        await coldStartFailed(kind);

        expect(reconnect(), isTrue);

        final again = controller.autoSignIn(AuthProvider.google);
        expect(again, isNotNull, reason: 'the re-arm must un-spend the launch');
        expect(auth.attempts, hasLength(2));
        expect(auth.reconnectedFlags, [false, true]);
        expect(
          auth.returnedFlags,
          [false, false],
          reason: 'nobody left the app — this is not the return surface',
        );
        expect(
          auth.autoFlags,
          [true, true],
          reason: 'sheet-first, exactly like the cold-start attempt',
        );

        auth.settleLast(const AuthCancelled());
        await again!;
      });
    }

    test(
      "GMS's offline picker cancel — `[16] Account reauth failed` — counts as a "
      'network failure, so the link coming back fires ONE attempt',
      () async {
        final first = controller.autoSignIn(AuthProvider.google)!;
        auth.settleLast(
          const AuthCancelled(outcome: SignInOutcome.reauthFailed),
        );
        await first;

        expect(reconnect(), isTrue);
        final again = controller.autoSignIn(AuthProvider.google);
        expect(again, isNotNull);
        expect(auth.reconnectedFlags, [false, true]);

        auth.settleLast(const AuthCancelled());
        await again!;
      },
    );

    test('a CANCEL is a refusal, not a dead link — no reconnect ever '
        'retries it', () async {
      final first = controller.autoSignIn(AuthProvider.google)!;
      auth.settleLast(const AuthCancelled());
      await first;

      expect(reconnect(), isFalse);
      expect(controller.autoSignIn(AuthProvider.google), isNull);
      expect(auth.attempts, hasLength(1));
    });

    test('the failures a working link cannot fix are never retried', () async {
      var at = 20;
      for (final kind in const [
        AuthFailureKind.noPlayServices,
        AuthFailureKind.serverError,
        AuthFailureKind.tokenExchangeFailed,
      ]) {
        final attempt = controller.signIn(AuthProvider.google, auto: true);
        auth.settleLast(AuthFailure(message: kind.name, kind: kind));
        await attempt;
        expect(reconnect(at: at), isFalse, reason: kind.name);
        at += 40;
      }
      expect(auth.attempts, hasLength(3), reason: 'one per attempt, no more');
    });

    test('an online reading with no offline one behind it is not a '
        'transition', () async {
      await coldStartFailed();

      clock = t0.add(const Duration(seconds: 20));
      expect(controller.noteConnectivity(online: true), isFalse);
      clock = t0.add(const Duration(seconds: 40));
      expect(controller.noteConnectivity(online: true), isFalse);
      expect(controller.autoSignIn(AuthProvider.google), isNull);
      expect(auth.attempts, hasLength(1));
    });

    test('a transition while an attempt is IN FLIGHT joins it, never a second '
        'surface', () async {
      await coldStartFailed();

      clock = t0.add(const Duration(seconds: 10));
      expect(controller.noteConnectivity(online: false), isFalse);
      final pill = controller.signIn(AuthProvider.google);
      clock = t0.add(const Duration(seconds: 20));
      expect(
        controller.noteConnectivity(online: true),
        isFalse,
        reason: 'the stall guard owns an attempt in flight, not this rule',
      );
      expect(auth.attempts, hasLength(2));

      auth.settleLast(const AuthCancelled());
      await pill;
    });

    test('a flapping link buys TWO re-arms and no more', () async {
      await coldStartFailed();

      for (final at in const [20, 60]) {
        expect(reconnect(at: at), isTrue);
        final again = controller.autoSignIn(AuthProvider.google)!;
        auth.settleLast(
          const AuthFailure(message: 'offline', kind: AuthFailureKind.unknown),
        );
        await again;
        // Every settle re-opens the per-failure allowance; the stretch budget is what runs out.
        clock = t0.add(Duration(seconds: at));
      }
      expect(auth.attempts, hasLength(3));

      // The third drop is the same story and gets nothing: a link at the edge of a cell would
      // otherwise redraw the sheet for as long as it flaps.
      clock = t0.add(const Duration(seconds: 100));
      expect(controller.noteConnectivity(online: false), isFalse);
      clock = t0.add(const Duration(seconds: 120));
      expect(controller.noteConnectivity(online: true), isFalse);
      expect(controller.autoSignIn(AuthProvider.google), isNull);
      expect(auth.attempts, hasLength(3));
    });

    test('ONE re-arm per failure — a second drop over the same dead attempt '
        'buys nothing', () async {
      await coldStartFailed();

      expect(reconnect(), isTrue);
      clock = t0.add(const Duration(seconds: 30));
      expect(controller.noteConnectivity(online: false), isFalse);
      clock = t0.add(const Duration(seconds: 40));
      expect(
        controller.noteConnectivity(online: true),
        isFalse,
        reason:
            'the failure\'s one re-arm was spent and nothing has settled since',
      );
    });

    test('a signed-in user is never handed a sheet by the link', () async {
      await coldStartFailed();
      auth.authed = true;

      expect(reconnect(), isFalse);
      expect(auth.attempts, hasLength(1));
    });

    test('a link that returns while our UI is NOT foregrounded opens '
        'nothing', () async {
      await coldStartFailed();
      controller.lifecycleProbe = () => AppLifecycleState.paused;

      expect(reconnect(), isFalse);
      expect(controller.autoSignIn(AuthProvider.google), isNull);
      expect(auth.attempts, hasLength(1));
    });
  });

  // The OS finishing Google's picker under us (an icon launch on the live task) reaches the app
  // as a `canceled` — in the FRAMEWORK's words, where a user's back-out carries GMS's words.
  // Measured on one phone in one minute; pinned here so the two can never be merged again.
  group('ApiAuthService.isSelectorStrip', () {
    test('the framework wording on the button flow is a strip', () {
      expect(
        ApiAuthService.isSelectorStrip(
          surface: 'button',
          description: 'User cancelled the selector',
        ),
        isTrue,
      );
      expect(
        ApiAuthService.isSelectorStrip(
          surface: 'button_after_dismiss',
          description: 'User cancelled the selector.',
        ),
        isTrue,
      );
      expect(
        ApiAuthService.isSelectorStrip(
          surface: 'button',
          description: 'User canceled the selector',
        ),
        isTrue,
        reason: 'both spellings, like the classifier',
      );
    });

    test("a user's own back-out of the picker is not", () {
      expect(
        ApiAuthService.isSelectorStrip(
          surface: 'button',
          description: '[16] Cancelled by user.',
        ),
        isFalse,
      );
    });

    test('the same wording on the SHEET is the user swiping it away', () {
      expect(
        ApiAuthService.isSelectorStrip(
          surface: 'sheet',
          description: 'User cancelled the selector',
        ),
        isFalse,
      );
      expect(
        ApiAuthService.isSelectorStrip(
          surface: 'sheet_return',
          description: 'User cancelled the selector',
        ),
        isFalse,
        reason: 'the return sheet is a sheet — a NAME, never a new behaviour',
      );
    });

    // The return marker is a VALUE on `surface`, and `surface` is read by more than analytics.
    // If a renamed sheet ever started matching here, a swipe on the return sheet would relaunch it
    // — the one thing the Credential Manager guide forbids.
    test('a returned sheet reports itself as sheet_return, and nothing else '
        'changes', () {
      expect(ApiAuthService.sheetSurfaceFor(returned: false), 'sheet');
      expect(ApiAuthService.sheetSurfaceFor(returned: true), 'sheet_return');
    });

    // Same reasoning for the reconnect sheet: a NAME on the attempt the link coming back re-armed,
    // never a surface of its own. A return outranks it — that person came back themselves.
    test('the sheet a reconnect re-armed names itself, and a return still '
        'wins', () {
      expect(
        ApiAuthService.sheetSurfaceFor(returned: false, reconnected: true),
        'sheet_reconnect',
      );
      expect(
        ApiAuthService.sheetSurfaceFor(returned: true, reconnected: true),
        'sheet_return',
      );
      expect(
        ApiAuthService.isSelectorStrip(
          surface: 'sheet_reconnect',
          description: 'User cancelled the selector',
        ),
        isFalse,
        reason: 'the reconnect sheet is a sheet — a swipe on it is the user',
      );
    });

    // The reopened picker is a BUTTON surface like any other: an icon relaunch can strip it too,
    // and a strip the service no longer recognised would be filed as the user saying no.
    test('the picker reopened after add-account names itself, and an OS strip '
        'of it is still a strip', () {
      expect(ApiAuthService.buttonSurfaceFor(reopened: false), 'button');
      expect(
        ApiAuthService.buttonSurfaceFor(reopened: true),
        'button_after_add_account',
      );
      expect(
        ApiAuthService.isSelectorStrip(
          surface: 'button_after_add_account',
          description: 'User cancelled the selector',
        ),
        isTrue,
      );
    });

    test('no surface or no message proves nothing', () {
      expect(
        ApiAuthService.isSelectorStrip(
          surface: null,
          description: 'User cancelled the selector',
        ),
        isFalse,
      );
      expect(
        ApiAuthService.isSelectorStrip(surface: 'button', description: null),
        isFalse,
      );
    });
  });

  group('AuthUserState', () {
    test('unauthenticated state has correct status', () {
      final state = AuthUserState.unauthenticated();
      expect(state.status, AuthStatus.unauthenticated);
      expect(state.isAuthenticated, isFalse);
      expect(state.userId, isNull);
    });

    test('authenticated state has correct fields', () {
      final state = AuthUserState.authenticated(
        userId: 'uid-1',
        displayName: 'Alice',
      );
      expect(state.status, AuthStatus.authenticated);
      expect(state.isAuthenticated, isTrue);
      expect(state.userId, 'uid-1');
      expect(state.displayName, 'Alice');
    });

    test('authenticated with null displayName is valid', () {
      final state = AuthUserState.authenticated(userId: 'uid-2');
      expect(state.displayName, isNull);
      expect(state.isAuthenticated, isTrue);
    });
  });

  // Credential Manager can drop its callback outright -> one attempt was observed still pending 13 minutes later.
  // The busy pill ignores taps -> without the guard that hang bricked sign-in for the whole process.
  // These pin the recovery path from both sides.
  group('AuthController stall guard', () {
    late _FakeAuthService auth;
    late AuthController controller;

    setUp(() {
      auth = _FakeAuthService();
      final container = ProviderContainer(
        overrides: [authServiceProvider.overrideWithValue(auth)],
      );
      addTearDown(container.dispose);
      controller = container.read(authControllerProvider.notifier)
        ..stallLimit = const Duration(milliseconds: 120)
        ..stallResumeGrace = const Duration(milliseconds: 40)
        ..stallTick = const Duration(milliseconds: 10)
        ..lifecycleProbe = (() => AppLifecycleState.resumed);
      // A process-wide notifier -> a test that leaves it true poisons the next one.
      SignInPhase.exchanging.value = false;
      addTearDown(() => SignInPhase.exchanging.value = false);
    });

    test('a foreground stall abandons the attempt, frees the pill, and lets '
        'a retry start FRESH', () async {
      final result = await controller.signIn(AuthProvider.google);

      expect(result, isA<AuthFailure>());
      expect(auth.abandonCount, 1, reason: 'zombie result must be discarded');

      final retry = controller.signIn(AuthProvider.google);
      expect(
        auth.attempts,
        hasLength(2),
        reason: 'the dead future must not be joined',
      );
      auth.settleLast(const AuthSuccess(userId: 'u1'));
      expect(await retry, isA<AuthSuccess>());
    });

    test('a stall while NOT resumed (sheet up / backgrounded) extends '
        'instead of abandoning', () async {
      controller.lifecycleProbe = () => AppLifecycleState.paused;

      final pending = controller.signIn(AuthProvider.google);
      // Well past stallLimit and several rechecks: still alive.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(
        auth.abandonCount,
        0,
        reason:
            'user may be mid-flow — never '
            'abandon under a sheet',
      );

      // The user finally picks an account.
      auth.settleLast(const AuthSuccess(userId: 'u1'));
      expect(await pending, isA<AuthSuccess>());
    });

    test('a caller joining a long-stalled attempt shares the ORIGINAL clock, '
        'not a fresh one', () async {
      // The auto attempt stalls (guard fires ~120ms in)...
      final first = controller.autoSignIn(AuthProvider.google)!;
      // ...and a recreated sign-in screen joins it late.
      await Future<void>.delayed(const Duration(milliseconds: 60));
      final joined = controller.autoSignIn(AuthProvider.google)!;
      expect(identical(first, joined), isTrue);

      expect(await joined, isA<AuthFailure>());
      expect(auth.abandonCount, 1);
    });

    test('coming back to the foreground RESTARTS the clock — a settle during '
        'the fresh budget wins, never the abandon', () async {
      // The device race -> the user sits in the account sheet past the stall budget, picks an account, the app resumes.
      // The token exchange is still in flight when the next recheck window expires.
      // Measured from the attempt's start the guard abandoned a healthy attempt -> measured from the RESUME it must not.
      var lifecycle = AppLifecycleState.paused;
      controller.lifecycleProbe = () => lifecycle;

      final pending = controller.signIn(AuthProvider.google);
      // Sheet up well past stallLimit (120ms), then the user picks: resume.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      // The credential is in hand and `POST /auth/login` is live -> this is the fresh-budget path,
      // and the only one that may have a full budget. Without it the resume falls to the grace.
      SignInPhase.exchanging.value = true;
      lifecycle = AppLifecycleState.resumed;
      // The exchange completes shortly after resume -> inside the fresh budget, long after the ORIGINAL clock expired.
      await Future<void>.delayed(const Duration(milliseconds: 60));
      auth.settleLast(const AuthSuccess(userId: 'u1'));

      expect(await pending, isA<AuthSuccess>());
      expect(
        auth.abandonCount,
        0,
        reason: 'post-sheet exchange is progress, not a stall',
      );
    });

    test(
      'an attempt still dead a FULL budget after resuming is abandoned',
      () async {
        var lifecycle = AppLifecycleState.paused;
        controller.lifecycleProbe = () => lifecycle;

        final pending = controller.signIn(AuthProvider.google);
        await Future<void>.delayed(const Duration(milliseconds: 200));
        // Our exchange is live -> the resume buys the FULL budget, not the grace.
        SignInPhase.exchanging.value = true;
        lifecycle = AppLifecycleState.resumed;
        // Never settled: the reset buys one fresh budget, not immunity.
        final result = await pending;

        expect(result, isA<AuthFailure>());
        expect(auth.abandonCount, 1);
      },
    );

    // ─── The LOST callback: resumed, nothing of ours running, no outcome ──────
    // A destroyed CredentialSelectorActivity completes nothing at all -> returning to it used to
    // buy the corpse another full budget. `exchanging` tells a corpse from a live exchange.

    test('resumed with NO exchange in flight abandons after the grace, not '
        'after another full budget', () async {
      var lifecycle = AppLifecycleState.paused;
      controller.lifecycleProbe = () => lifecycle;

      final pending = controller.signIn(AuthProvider.google);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      // The sheet is gone and nothing of ours is running.
      lifecycle = AppLifecycleState.resumed;

      // Grace 40ms + slack, but well inside another full budget (120ms).
      await Future<void>.delayed(const Duration(milliseconds: 90));
      expect(
        auth.abandonCount,
        1,
        reason: 'the corpse is discarded after the 40ms grace, not 120ms more',
      );
      expect(
        auth.attempts,
        hasLength(2),
        reason: 'a lost callback is relaunched, not just reported',
      );
      auth.settleLast(const AuthSuccess(userId: 'u1'));
      expect(await pending, isA<AuthSuccess>());
    });

    // ─── Home and back through the icon: clearTaskOnLaunch strips Google's surface ───────────
    // The old guard slept through its whole budget and only then read the lifecycle -> a return
    // INSIDE the budget was invisible and the pill spun to "taking too long". Three variants
    // reproduced on device (sheet up, picker up, after the account tap).

    test('a return to the foreground BEFORE the budget runs out, with no '
        'exchange in flight, relaunches after the grace instead of spinning '
        'out the budget', () async {
      var lifecycle = AppLifecycleState.paused;
      controller.lifecycleProbe = () => lifecycle;

      final pending = controller.signIn(AuthProvider.google);
      // Sheet up for a moment, well inside the 120ms budget...
      await Future<void>.delayed(const Duration(milliseconds: 40));
      // ...then Home and back through the icon: the sheet is gone and nothing will ever land.
      lifecycle = AppLifecycleState.resumed;

      // Grace 40ms + a few ticks — long before the budget would have expired.
      await Future<void>.delayed(const Duration(milliseconds: 70));
      expect(auth.abandonCount, 1, reason: 'the corpse goes after the grace');
      expect(auth.attempts, hasLength(2), reason: 'and a fresh surface opens');
      auth.settleLast(const AuthSuccess(userId: 'u1'));
      expect(await pending, isA<AuthSuccess>());
    });

    test('a `canceled` the service classified as the OS stripping the picker '
        'is relaunched once, not returned', () async {
      var lifecycle = AppLifecycleState.paused;
      controller.lifecycleProbe = () => lifecycle;

      final pending = controller.signIn(AuthProvider.google);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      lifecycle = AppLifecycleState.resumed;
      auth.settleLast(
        const AuthCancelled(outcome: SignInOutcome.selectorStripped),
      );

      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(auth.attempts, hasLength(2), reason: 'nobody dismissed anything');
      expect(auth.abandonCount, 1);
      auth.settleLast(const AuthSuccess(userId: 'u1'));
      expect(await pending, isA<AuthSuccess>());
    });

    test(
      'a second strip after the one relaunch is returned, never looped',
      () async {
        var lifecycle = AppLifecycleState.paused;
        controller.lifecycleProbe = () => lifecycle;

        final pending = controller.signIn(AuthProvider.google);
        await Future<void>.delayed(const Duration(milliseconds: 40));
        lifecycle = AppLifecycleState.resumed;
        auth.settleLast(
          const AuthCancelled(outcome: SignInOutcome.selectorStripped),
        );
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(auth.attempts, hasLength(2));
        auth.settleLast(
          const AuthCancelled(outcome: SignInOutcome.selectorStripped),
        );

        expect(await pending, isA<AuthCancelled>());
        expect(auth.attempts, hasLength(2), reason: 'one-shot');
      },
    );

    test(
      'a plain `canceled` is the user saying no and is returned untouched',
      () async {
        var lifecycle = AppLifecycleState.paused;
        controller.lifecycleProbe = () => lifecycle;

        final pending = controller.signIn(AuthProvider.google);
        await Future<void>.delayed(const Duration(milliseconds: 40));
        lifecycle = AppLifecycleState.resumed;
        auth.settleLast(const AuthCancelled());

        expect(await pending, isA<AuthCancelled>());
        expect(auth.attempts, hasLength(1));
        expect(auth.abandonCount, 0);
      },
    );

    // Google's add-account flow hands the user back with ONE message whether they added an
    // account, gave up or were bounced -> nothing reopened, and 76% of them cancelled again.
    test('a return from add-account reopens the PICKER once: button flow, '
        'stamped, nothing abandoned', () async {
      final pending = controller.signIn(AuthProvider.google, auto: true);
      auth.settleLast(
        const AuthCancelled(outcome: SignInOutcome.addAccountAbandoned),
      );

      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(auth.attempts, hasLength(2), reason: 'the picker comes back');
      expect(
        auth.autoFlags.last,
        isFalse,
        reason: 'never the One Tap sheet — a cancel must not redraw it',
      );
      expect(auth.reopenedFlags, [false, true]);
      expect(auth.returnedFlags.last, isFalse);
      expect(auth.abandonCount, 0, reason: 'the first attempt SETTLED');

      auth.settleLast(const AuthSuccess(userId: 'u1'));
      expect(await pending, isA<AuthSuccess>());
    });

    test('a second add-account return is handed back, never looped', () async {
      final pending = controller.signIn(AuthProvider.google);
      auth.settleLast(
        const AuthCancelled(outcome: SignInOutcome.addAccountAbandoned),
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(auth.attempts, hasLength(2));
      auth.settleLast(
        const AuthCancelled(outcome: SignInOutcome.addAccountAbandoned),
      );

      final result = await pending;
      expect(result, isA<AuthCancelled>());
      expect(
        (result as AuthCancelled).outcome,
        SignInOutcome.addAccountAbandoned,
      );
      expect(auth.attempts, hasLength(2), reason: 'one-shot');
    });

    test('an add-account return that lands while we are still behind another '
        'app reopens nothing', () async {
      controller.lifecycleProbe = () => AppLifecycleState.paused;

      final pending = controller.signIn(AuthProvider.google);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      auth.settleLast(
        const AuthCancelled(outcome: SignInOutcome.addAccountAbandoned),
      );

      expect(await pending, isA<AuthCancelled>());
      expect(auth.attempts, hasLength(1), reason: 'no surface from behind');
    });

    test('an add-account return that lands a beat BEFORE our resume still '
        'reopens', () async {
      var lifecycle = AppLifecycleState.inactive;
      controller.lifecycleProbe = () => lifecycle;

      final pending = controller.signIn(AuthProvider.google);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      auth.settleLast(
        const AuthCancelled(outcome: SignInOutcome.addAccountAbandoned),
      );
      await Future<void>.delayed(const Duration(milliseconds: 15));
      expect(auth.attempts, hasLength(1), reason: 'not resumed yet');
      lifecycle = AppLifecycleState.resumed;

      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(auth.attempts, hasLength(2));
      auth.settleLast(const AuthSuccess(userId: 'u1'));
      expect(await pending, isA<AuthSuccess>());
    });

    // "Tap again" can never work on a phone whose Play services cannot sign in.
    for (final fix in PlayServicesFix.values) {
      test("a Play services failure asks for Google's dialog once and is "
          'still returned as it was (native answers ${fix.name})', () async {
        final resolver = _FakeResolver(fix);
        controller.playServices = resolver;

        final pending = controller.signIn(AuthProvider.google);
        auth.settleLast(
          const AuthFailure(message: 'x', kind: AuthFailureKind.noPlayServices),
        );

        final result = await pending;
        expect(result, isA<AuthFailure>());
        expect((result as AuthFailure).kind, AuthFailureKind.noPlayServices);
        expect(resolver.calls, 1);
        expect(
          auth.attempts,
          hasLength(1),
          reason: 'the way back in is the return from the Play Store',
        );
      });
    }

    test('a dialog call that never answers cannot hold the pill', () async {
      controller.playServices = _FakeResolver.hanging();

      final pending = controller.signIn(AuthProvider.google);
      auth.settleLast(
        const AuthFailure(message: 'x', kind: AuthFailureKind.noPlayServices),
      );

      final result = await pending.timeout(const Duration(seconds: 1));
      expect(result, isA<AuthFailure>());
      expect(auth.attempts, hasLength(1));
    });

    test('any other failure never reaches the repair', () async {
      final resolver = _FakeResolver(PlayServicesFix.shown);
      controller.playServices = resolver;

      final pending = controller.signIn(AuthProvider.google);
      auth.settleLast(
        const AuthFailure(message: 'x', kind: AuthFailureKind.networkError),
      );

      expect(await pending, isA<AuthFailure>());
      expect(resolver.calls, 0);
      expect(auth.attempts, hasLength(1));
    });

    test('the relaunch is ONE-SHOT — a second lost sheet reports instead of '
        'looping', () async {
      var lifecycle = AppLifecycleState.paused;
      controller.lifecycleProbe = () => lifecycle;

      final pending = controller.signIn(AuthProvider.google);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      lifecycle = AppLifecycleState.resumed;

      expect(await pending, isA<AuthFailure>());
      expect(
        auth.attempts,
        hasLength(2),
        reason: 'exactly one relaunch, never a third sheet',
      );
    });

    test('a DISMISSED sheet is never relaunched — the cancel settles inside '
        'the grace', () async {
      var lifecycle = AppLifecycleState.paused;
      controller.lifecycleProbe = () => lifecycle;

      final pending = controller.signIn(AuthProvider.google);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      lifecycle = AppLifecycleState.resumed;
      // A cancellation is a RESULT: it arrives on the same future, inside the grace.
      auth.settleLast(
        const AuthFailure(message: 'cancelled', kind: AuthFailureKind.unknown),
      );

      expect(await pending, isA<AuthFailure>());
      expect(
        auth.attempts,
        hasLength(1),
        reason: 'no second sheet on a cancel',
      );
      expect(auth.abandonCount, 0);
    });

    test(
      'the grace never runs while PAUSED — a sheet back on top extends',
      () async {
        var lifecycle = AppLifecycleState.paused;
        controller.lifecycleProbe = () => lifecycle;

        final pending = controller.signIn(AuthProvider.google);
        await Future<void>.delayed(const Duration(milliseconds: 200));
        // Returning by RECENTS: resumed for an instant, then the sheet is back on top.
        lifecycle = AppLifecycleState.resumed;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        lifecycle = AppLifecycleState.paused;
        await Future<void>.delayed(const Duration(milliseconds: 300));

        expect(
          auth.abandonCount,
          0,
          reason: 'a surface on top is mid-flow, whatever the grace saw',
        );
        expect(auth.attempts, hasLength(1));
        auth.settleLast(const AuthSuccess(userId: 'u1'));
        expect(await pending, isA<AuthSuccess>());
      },
    );

    test('a settle before the limit never trips the guard', () async {
      final pending = controller.signIn(AuthProvider.google);
      auth.settleLast(const AuthSuccess(userId: 'u1'));
      expect(await pending, isA<AuthSuccess>());
      expect(auth.abandonCount, 0);
    });
  });

  // The old classifier string-sniffed for "cancel" -> Credential Manager phrases REAL failures that way.
  // A token mint dying on a fresh LTE link surfaced as a silent pill-bounce -> typed codes only.
  // The enum is documented non-exhaustive -> unknowns must stay visible.
  group('mapGoogleSignInException', () {
    AuthResult map(GoogleSignInExceptionCode code) =>
        ApiAuthService.mapGoogleSignInException(
          GoogleSignInException(code: code),
        );

    test('only a user cancel is quiet', () {
      expect(map(GoogleSignInExceptionCode.canceled), isA<AuthCancelled>());
    });

    test('interrupted surfaces as a retryable network failure', () {
      final r = map(GoogleSignInExceptionCode.interrupted);
      expect(r, isA<AuthFailure>());
      expect((r as AuthFailure).kind, AuthFailureKind.networkError);
    });

    test('provider config errors point at Play Services', () {
      final r = map(GoogleSignInExceptionCode.providerConfigurationError);
      expect((r as AuthFailure).kind, AuthFailureKind.noPlayServices);
    });

    test('everything else — including future codes — falls through VISIBLE, '
        'never quiet', () {
      for (final code in [
        GoogleSignInExceptionCode.unknownError,
        GoogleSignInExceptionCode.clientConfigurationError,
        GoogleSignInExceptionCode.uiUnavailable,
        GoogleSignInExceptionCode.userMismatch,
      ]) {
        expect(map(code), isA<AuthFailure>(), reason: '$code must be visible');
      }
    });
  });

  // The exchange-retry policy proven on device -> the one blackout loss was this POST timing out on a recovered link.
  // The Google credential was already in hand -> a lost exchange must never cost a second account picker.
  group('postWithNetworkRetry', () {
    test(
      'retries a connectivity failure and returns the retry result',
      () async {
        var calls = 0;
        final out = await ApiAuthService.postWithNetworkRetry(() async {
          calls++;
          if (calls == 1) throw http.ClientException('Request timed out');
          return {'ok': true};
        }, backoff: Duration.zero);
        expect(calls, 2);
        expect(out['ok'], true);
      },
    );

    test('never retries a server response, even a 5xx', () async {
      var calls = 0;
      await expectLater(
        ApiAuthService.postWithNetworkRetry(() async {
          calls++;
          throw const ApiException(
            code: 'server_error',
            message: 'boom',
            status: 500,
          );
        }, backoff: Duration.zero),
        throwsA(isA<ApiException>()),
      );
      expect(calls, 1);
    });

    test('gives up after maxAttempts and rethrows the network error', () async {
      var calls = 0;
      await expectLater(
        ApiAuthService.postWithNetworkRetry(() async {
          calls++;
          throw const SocketException('Failed host lookup');
        }, backoff: Duration.zero),
        throwsA(isA<SocketException>()),
      );
      expect(calls, 3);
    });

    test('stops retrying once the elapsed cap has passed', () async {
      var calls = 0;
      await expectLater(
        ApiAuthService.postWithNetworkRetry(
          () async {
            calls++;
            throw http.ClientException('timeout');
          },
          elapsedCap: Duration.zero,
          backoff: Duration.zero,
        ),
        throwsA(isA<http.ClientException>()),
      );
      expect(calls, 1);
    });
  });

  // Google's guide puts the Credential Manager bottom sheet FIRST and the button flow behind it.
  // Hard stop -> a credential from the sheet ENDS the attempt; nothing follows a success.
  // A dismissal escalates ONCE, and only ever to the button flow: re-drawing the One Tap sheet
  // spends the user's 24 h cancel budget, which would cost them automatic sign-in too.
  group('resolveGoogleCredential — surface order', () {
    late List<String> surfaces;
    late List<GoogleSignInException> unavailable;
    late int buttonCalls;

    setUp(() {
      surfaces = [];
      unavailable = [];
      buttonCalls = 0;
    });

    Future<String> run({
      Future<String?>? Function()? sheet,
      String sheetSurface = 'sheet',
    }) => ApiAuthService.resolveGoogleCredential<String>(
      sheet: sheet,
      sheetSurface: sheetSurface,
      button: () async {
        buttonCalls++;
        return 'button-credential';
      },
      onSurface: surfaces.add,
      onSheetUnavailable: unavailable.add,
    );

    test('a credential from the sheet is the whole attempt — no picker after '
        'it', () async {
      final out = await run(sheet: () async => 'sheet-credential');

      expect(out, 'sheet-credential');
      expect(buttonCalls, 0, reason: 'ONE Google surface per attempt');
      expect(surfaces, ['sheet']);
    });

    test(
      'a sheet that drew NOTHING (null) falls through to the button',
      () async {
        // No accounts, "Sign-in prompts" off, or no credential after both native steps -> the user saw nothing.
        // So the button is still their first surface.
        final out = await run(sheet: () async => null);

        expect(out, 'button-credential');
        expect(surfaces, ['sheet', 'button']);
        expect(unavailable, isEmpty, reason: 'nothing failed — it was empty');
      },
    );

    test(
      'a null sheet FUTURE (no lightweight flow here) falls through too',
      () async {
        final out = await run(sheet: () => null);

        expect(out, 'button-credential');
        expect(buttonCalls, 1);
      },
    );

    test('a DISMISSED sheet escalates ONCE to the button flow', () async {
      final out = await run(
        sheet: () async => throw const GoogleSignInException(
          code: GoogleSignInExceptionCode.canceled,
          description: 'activity is cancelled by the user',
        ),
      );

      expect(out, 'button-credential');
      expect(buttonCalls, 1, reason: 'ONCE — the button flow, never the sheet');
      expect(unavailable, isEmpty, reason: 'a dismissal is not a failure');
    });

    test(
      'and it is reported under its OWN surface — a picker the user has '
      'already refused once cannot be averaged with one they have not',
      () async {
        await run(
          sheet: () async => throw const GoogleSignInException(
            code: GoogleSignInExceptionCode.canceled,
          ),
        );

        expect(surfaces, ['sheet', 'button_after_dismiss']);
      },
    );

    // The return marker rides the SHEET's name only. A dismissal escalates to the same
    // `button_after_dismiss` it always did, so the return attempt's marker lives on its
    // `login_attempt` alone and the picker's own conversion stays one comparable bucket.
    test(
      'a RETURN attempt renames its sheet and leaves the escalation alone',
      () async {
        final out = await run(
          sheet: () async => 'sheet-credential',
          sheetSurface: 'sheet_return',
        );
        expect(out, 'sheet-credential');
        expect(surfaces, ['sheet_return']);

        surfaces = [];
        await run(
          sheet: () async => throw const GoogleSignInException(
            code: GoogleSignInExceptionCode.canceled,
          ),
          sheetSurface: 'sheet_return',
        );
        expect(surfaces, ['sheet_return', 'button_after_dismiss']);
      },
    );

    test('every OTHER sheet failure is reported and falls through to the '
        'button', () async {
      for (final code in [
        GoogleSignInExceptionCode.uiUnavailable,
        GoogleSignInExceptionCode.interrupted,
        // Where an Android 14 TransactionTooLargeException lands on GMS < 24.40.
        GoogleSignInExceptionCode.unknownError,
        GoogleSignInExceptionCode.providerConfigurationError,
        GoogleSignInExceptionCode.clientConfigurationError,
      ]) {
        surfaces = [];
        unavailable = [];
        buttonCalls = 0;

        final out = await run(
          sheet: () async => throw GoogleSignInException(code: code),
        );

        expect(out, 'button-credential', reason: '$code must not end sign-in');
        expect(surfaces, ['sheet', 'button']);
        expect(unavailable.single.code, code, reason: 'counted, not swallowed');
      }
    });

    test(
      'the pill (no sheet) opens the button flow and nothing else',
      () async {
        final out = await run();

        expect(out, 'button-credential');
        expect(surfaces, ['button'], reason: 'a tap is already past the sheet');
      },
    );
  });

  // The nonce binds an ID token to the process that asked for it -> the plugin accepts one only at initialize().
  // It attaches that nonce to every request after -> the Worker rejects a login whose request nonce and claim differ.
  group('GoogleSignInInit nonce', () {
    setUp(GoogleSignInInit.resetForTest);
    tearDown(GoogleSignInInit.resetForTest);

    test('is 32 random bytes, unpadded base64url — Google\'s own shape', () {
      final nonce = GoogleSignInInit.generateNonce();

      expect(nonce, matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
      expect(base64Url.decode(base64.normalize(nonce)), hasLength(32));
      expect(
        GoogleSignInInit.generateNonce(),
        isNot(nonce),
        reason: 'a reused nonce protects nothing',
      );
    });

    test('start() records the nonce for the exchange to send', () async {
      GoogleSignInInit.start(serverClientId: 'server-client-id', nonce: 'n-1');

      expect(GoogleSignInInit.nonce, 'n-1');
      // Never throws, even with no platform implementation behind it.
      await GoogleSignInInit.ready;
    });

    test(
      'a second start() keeps the FIRST nonce — the tokens are bound to it',
      () {
        GoogleSignInInit.start(
          serverClientId: 'server-client-id',
          nonce: 'n-1',
        );
        GoogleSignInInit.start(
          serverClientId: 'server-client-id',
          nonce: 'n-2',
        );

        expect(GoogleSignInInit.nonce, 'n-1');
      },
    );

    test('no nonce at all when start() never ran (define-less runs)', () {
      expect(GoogleSignInInit.nonce, isNull);
    });
  });
}
