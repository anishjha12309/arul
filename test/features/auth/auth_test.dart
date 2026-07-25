import 'package:flutter_test/flutter_test.dart';
import 'package:arul/features/auth/domain/auth_service.dart';

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
}
