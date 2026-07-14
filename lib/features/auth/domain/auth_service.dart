/// The auth providers the app supports. Add new values here when new providers
/// are integrated — do NOT add provider-specific logic to widgets or the router.
enum AuthProvider { google }

/// Possible ways a sign-in attempt can resolve.
sealed class AuthResult {
  const AuthResult();
}

final class AuthSuccess extends AuthResult {
  const AuthSuccess({required this.userId});
  final String userId;
}

final class AuthCancelled extends AuthResult {
  const AuthCancelled();
}

final class AuthFailure extends AuthResult {
  const AuthFailure({required this.message, required this.kind});
  final String message;
  final AuthFailureKind kind;
}

enum AuthFailureKind {
  noPlayServices,
  networkError,
  tokenExchangeFailed,
  serverError,
  unknown,
}

// ─── Auth state ──────────────────────────────────────────────────────────────

enum AuthStatus { unauthenticated, authenticated }

final class AuthUserState {
  const AuthUserState._({
    required this.status,
    this.userId,
    this.displayName,
    this.email,
  });

  factory AuthUserState.unauthenticated() =>
      const AuthUserState._(status: AuthStatus.unauthenticated);

  factory AuthUserState.authenticated({
    required String userId,
    String? displayName,
    String? email,
  }) => AuthUserState._(
    status: AuthStatus.authenticated,
    userId: userId,
    displayName: displayName,
    email: email,
  );

  final AuthStatus status;
  final String? userId;
  final String? displayName;
  final String? email;

  bool get isAuthenticated => status == AuthStatus.authenticated;

  /// Returns a copy with the given fields overridden. Only valid on an
  /// authenticated state.
  AuthUserState copyWith({String? displayName, String? email}) =>
      AuthUserState._(
        status: status,
        userId: userId,
        displayName: displayName ?? this.displayName,
        email: email ?? this.email,
      );
}

// ─── Service interface ────────────────────────────────────────────────────────

/// Abstraction over the auth backend so widgets and the router never touch a
/// provider SDK directly.
abstract interface class AuthService {
  /// Stream of auth state changes. Fires an initial event immediately.
  Stream<AuthUserState> get authStateChanges;

  /// Current auth state (synchronous snapshot).
  AuthUserState get currentState;

  /// Completes once the initial stored-session check has finished and
  /// [currentState] reflects the real verdict. The splash awaits this so a
  /// returning user is never routed to sign-in just because the encrypted
  /// token read hadn't finished yet.
  Future<void> get initialized;

  /// Attempt sign-in via the given provider.
  Future<AuthResult> signInWith(AuthProvider provider);

  /// Update the current user's display name. The trimmed [name] is sent to the
  /// Worker; on success the new name is reflected in [authStateChanges].
  /// Throws on failure (e.g. network / validation) so the caller can surface it.
  Future<void> updateDisplayName(String name);

  /// Sign out the current user.
  Future<void> signOut();

  /// Permanently delete the current user's account on the server (revokes any
  /// live payment mandate, then removes all data) and clear the local session.
  /// Throws on failure — the account is NOT deleted and the session stays —
  /// so the caller can surface the error.
  Future<void> deleteAccount();
}
