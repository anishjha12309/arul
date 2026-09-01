import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:arul/core/api/api_client.dart';
import 'package:arul/core/auth/google_sign_in_init.dart';
import 'package:arul/features/auth/data/api_auth_service.dart';
import 'package:arul/features/auth/domain/auth_service.dart';
import 'package:arul/features/auth/providers/auth_providers.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;

/// Records every `signInWith` call and lets the test settle them by hand, so
/// "was a second picker opened?" is answerable as a plain call count.
class _FakeAuthService implements AuthService {
  final List<Completer<AuthResult>> attempts = [];
  int signOutCount = 0;
  int abandonCount = 0;

  final List<bool> autoFlags = [];

  @override
  Future<AuthResult> signInWith(AuthProvider provider, {bool auto = false}) {
    final completer = Completer<AuthResult>();
    attempts.add(completer);
    autoFlags.add(auto);
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
  AuthUserState get currentState => AuthUserState.unauthenticated();

  @override
  Future<void> get initialized async {}

  @override
  Future<void> updateDisplayName(String name) async {}
}

// ─── Domain model tests ───────────────────────────────────────────────────────

void main() {
  // Google's account picker is a system Activity: two overlapping attempts put
  // two sheets on screen, and zero attempts strand the user on a dead screen.
  // Both shipped once (2026-08-11) — these pin the guard from either side.
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
      // The splash fires the auto attempt fire-and-forget; a fast failure
      // (e.g. no Play Services) settles before the sign-in screen mounts.
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

  // Credential Manager can drop its callback outright — one attempt observed
  // still pending 13 minutes later (device 2026-08-18). The busy pill ignores
  // taps, so without the guard that hang bricked sign-in for the whole
  // process. These pin the recovery path from both sides.
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
        ..stallRecheck = const Duration(milliseconds: 40)
        ..lifecycleProbe = (() => AppLifecycleState.resumed);
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
      // The 2026-08-22 device race: user sits in the account sheet past the
      // stall budget, picks an account (app resumes), and the token exchange
      // is still in flight when the next recheck window expires. Measured
      // from the attempt's start the guard abandoned that healthy attempt;
      // measured from the RESUME it must not.
      var lifecycle = AppLifecycleState.paused;
      controller.lifecycleProbe = () => lifecycle;

      final pending = controller.signIn(AuthProvider.google);
      // Sheet up well past stallLimit (120ms), then the user picks: resume.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      lifecycle = AppLifecycleState.resumed;
      // The exchange completes shortly after resume — inside the fresh
      // budget, but long after the ORIGINAL clock expired.
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
        lifecycle = AppLifecycleState.resumed;
        // Never settled: the reset buys one fresh budget, not immunity.
        final result = await pending;

        expect(result, isA<AuthFailure>());
        expect(auth.abandonCount, 1);
      },
    );

    test('a settle before the limit never trips the guard', () async {
      final pending = controller.signIn(AuthProvider.google);
      auth.settleLast(const AuthSuccess(userId: 'u1'));
      expect(await pending, isA<AuthSuccess>());
      expect(auth.abandonCount, 0);
    });
  });

  // The old classifier string-sniffed for "cancel" — and Credential Manager
  // phrases REAL failures that way (a token mint dying on a fresh LTE link
  // surfaced as a silent pill-bounce, device 2026-08-18). Typed codes only;
  // the enum is documented non-exhaustive, so unknowns must stay visible.
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

  // Pins the exchange-retry policy proven on device (2026-08-31 matrix): the
  // one blackout loss was this POST timing out on an already-recovered link
  // with the Google credential in hand — a lost exchange must never cost a
  // second account picker when a retry can land it.
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

  // Google's 2026 "Implement Sign in with Google" guide puts the Credential
  // Manager bottom sheet FIRST and the button flow behind it. These pin the
  // order and, just as importantly, its two hard stops: never a second surface
  // in one attempt, and never a picker over a sheet the user dismissed.
  group('resolveGoogleCredential — surface order', () {
    late List<String> surfaces;
    late List<GoogleSignInException> unavailable;
    late int buttonCalls;

    setUp(() {
      surfaces = [];
      unavailable = [];
      buttonCalls = 0;
    });

    Future<String> run({Future<String?>? Function()? sheet}) =>
        ApiAuthService.resolveGoogleCredential<String>(
          sheet: sheet,
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

    test('a sheet that drew NOTHING (null) falls through to the button', () async {
      // No accounts, "Sign-in prompts" off, or no credential after both native
      // steps: the user saw nothing, so the button is still their first surface.
      final out = await run(sheet: () async => null);

      expect(out, 'button-credential');
      expect(surfaces, ['sheet', 'button']);
      expect(unavailable, isEmpty, reason: 'nothing failed — it was empty');
    });

    test(
      'a null sheet FUTURE (no lightweight flow here) falls through too',
      () async {
        final out = await run(sheet: () => null);

        expect(out, 'button-credential');
        expect(buttonCalls, 1);
      },
    );

    test(
      'a DISMISSED sheet STOPS the attempt — never a picker over it',
      () async {
        await expectLater(
          run(
            sheet: () async => throw const GoogleSignInException(
              code: GoogleSignInExceptionCode.canceled,
              description: 'activity is cancelled by the user',
            ),
          ),
          throwsA(isA<GoogleSignInException>()),
        );

        expect(buttonCalls, 0, reason: 'the guide forbids retrying a cancel');
        expect(surfaces, ['sheet']);
        expect(unavailable, isEmpty, reason: 'a dismissal is not a failure');
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

  // The nonce binds an ID token to the process that asked for it: the plugin
  // accepts one only at initialize() and attaches it to every request after,
  // and the Worker rejects a login whose request nonce and token claim differ.
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
