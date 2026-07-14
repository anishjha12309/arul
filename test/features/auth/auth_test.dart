import 'package:flutter_test/flutter_test.dart';
import 'package:arul/features/auth/domain/auth_service.dart';
import 'package:arul/features/auth/domain/profile_repository.dart';

// ─── Fakes ────────────────────────────────────────────────────────────────────

class _FakeAuthService implements AuthService {
  _FakeAuthService({required AuthUserState initialState})
    : _state = initialState;

  AuthUserState _state;
  final List<void Function(AuthUserState)> _listeners = [];

  void emit(AuthUserState state) {
    _state = state;
    for (final l in List.of(_listeners)) {
      l(state);
    }
  }

  @override
  Stream<AuthUserState> get authStateChanges => Stream.multi((controller) {
    // Emit current state immediately so subscribers always get an event.
    controller.add(_state);
    void onChange(AuthUserState s) => controller.add(s);
    _listeners.add(onChange);
    controller.onCancel = () => _listeners.remove(onChange);
  });

  @override
  AuthUserState get currentState => _state;

  @override
  Future<void> get initialized => Future.value();

  @override
  Future<AuthResult> signInWith(AuthProvider provider) async =>
      throw UnimplementedError();

  @override
  Future<void> updateDisplayName(String name) async {
    if (_state.isAuthenticated) emit(_state.copyWith(displayName: name.trim()));
  }

  @override
  Future<void> signOut() async => emit(AuthUserState.unauthenticated());

  @override
  Future<void> deleteAccount() async => emit(AuthUserState.unauthenticated());
}

class _FakeProfileRepository implements ProfileRepository {
  int upsertCallCount = 0;
  String? lastUserId;

  @override
  Future<void> upsertOnFirstLogin({
    required String userId,
    required String? displayName,
  }) async {
    upsertCallCount++;
    lastUserId = userId;
  }

  @override
  Future<Map<String, dynamic>?> getProfile(String userId) async => null;

  @override
  Future<void> updateProfile(
    String userId, {
    String? displayName,
    bool? statusShowPhoto,
    bool? statusShowName,
  }) async {}
}

// ─── Domain model tests ───────────────────────────────────────────────────────

void main() {
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

  group('AuthResult', () {
    test('AuthSuccess carries userId', () {
      const r = AuthSuccess(userId: 'abc');
      expect(r.userId, 'abc');
    });

    test('AuthCancelled is a distinct type', () {
      const r = AuthCancelled();
      expect(r, isA<AuthCancelled>());
    });

    test('AuthFailure carries message and kind', () {
      const r = AuthFailure(
        message: 'Network error',
        kind: AuthFailureKind.networkError,
      );
      expect(r.message, 'Network error');
      expect(r.kind, AuthFailureKind.networkError);
    });
  });

  group('AuthService stream', () {
    test('emits initial state immediately', () async {
      final service = _FakeAuthService(
        initialState: AuthUserState.unauthenticated(),
      );
      final first = await service.authStateChanges.first.timeout(
        const Duration(seconds: 1),
        onTimeout: () => throw TimeoutException(),
      );
      expect(first, isA<AuthUserState>());
    });

    test('transitions Unauthenticated → Authenticated on sign-in', () async {
      final service = _FakeAuthService(
        initialState: AuthUserState.unauthenticated(),
      );

      final states = <AuthUserState>[];
      final sub = service.authStateChanges.listen(states.add);

      // Initial state is emitted on subscribe; only emit the transition.
      service.emit(AuthUserState.authenticated(userId: 'uid-99'));

      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(states.length, 2);
      expect(states[0].status, AuthStatus.unauthenticated);
      expect(states[1].status, AuthStatus.authenticated);
      expect(states[1].userId, 'uid-99');
    });

    test('sign-out returns to Unauthenticated', () async {
      final service = _FakeAuthService(
        initialState: AuthUserState.authenticated(userId: 'uid-1'),
      );

      await service.signOut();
      expect(service.currentState.status, AuthStatus.unauthenticated);
    });
  });

  group('ProfileRepository', () {
    test('upsertOnFirstLogin records userId', () async {
      final repo = _FakeProfileRepository();
      await repo.upsertOnFirstLogin(userId: 'uid-1', displayName: 'Alice');
      expect(repo.upsertCallCount, 1);
      expect(repo.lastUserId, 'uid-1');
    });

    test('upsert is not called if userId is never provided', () {
      final repo = _FakeProfileRepository();
      expect(repo.upsertCallCount, 0);
    });
  });

  group('AuthProvider enum', () {
    test('exposes the supported providers', () {
      expect(AuthProvider.values, contains(AuthProvider.google));
    });
  });
}

class TimeoutException implements Exception {
  @override
  String toString() => 'Stream did not emit within timeout';
}
