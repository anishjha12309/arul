import 'dart:async';

import 'package:arul/features/auth/data/api_auth_service.dart';
import 'package:arul/features/auth/domain/auth_service.dart';
import 'package:arul/features/auth/providers/auth_providers.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in/google_sign_in.dart';

/// Records every `signInWith` call and lets the test settle them by hand, so
/// "was a second picker opened?" is answerable as a plain call count.
class _FakeAuthService implements AuthService {
  final List<Completer<AuthResult>> attempts = [];
  int signOutCount = 0;
  int abandonCount = 0;

  @override
  Future<AuthResult> signInWith(AuthProvider provider) {
    final completer = Completer<AuthResult>();
    attempts.add(completer);
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
}
