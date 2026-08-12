import 'dart:async';

import 'package:arul/features/auth/domain/auth_service.dart';
import 'package:arul/features/auth/providers/auth_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records every `signInWith` call and lets the test settle them by hand, so
/// "was a second picker opened?" is answerable as a plain call count.
class _FakeAuthService implements AuthService {
  final List<Completer<AuthResult>> attempts = [];
  int signOutCount = 0;

  @override
  Future<AuthResult> signInWith(AuthProvider provider) {
    final completer = Completer<AuthResult>();
    attempts.add(completer);
    return completer.future;
  }

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
}
