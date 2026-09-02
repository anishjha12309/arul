import 'package:flutter/foundation.dart';

/// The auth providers the app supports — never put provider-specific logic in widgets or the router.
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

/// The one wait during sign-in that the APP owns.
///
/// Everything up to the credential is Google's own UI -> the app has nothing to say about it.
/// `POST /auth/login` is ours and can take 25.5s with retries -> a busy pill alone reads as dead.
/// True only for that window; reset per attempt.
/// UI-only state that gates nothing -> a plain notifier, not a member every test fake must grow.
abstract final class SignInPhase {
  static final ValueNotifier<bool> exchanging = ValueNotifier<bool>(false);
}

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

  /// A copy with the given fields overridden. Only valid on an authenticated state.
  AuthUserState copyWith({String? displayName, String? email}) =>
      AuthUserState._(
        status: status,
        userId: userId,
        displayName: displayName ?? this.displayName,
        email: email ?? this.email,
      );
}

/// Abstraction over the auth backend -> widgets and the router never touch a provider SDK.
abstract interface class AuthService {
  /// Stream of auth state changes. Fires an initial event immediately.
  Stream<AuthUserState> get authStateChanges;

  /// Current auth state (synchronous snapshot).
  AuthUserState get currentState;

  /// Completes once the stored-session check has finished and [currentState] is the real verdict.
  /// The splash awaits it -> a returning user is never bounced to sign-in on an unfinished read.
  Future<void> get initialized;

  /// Attempt sign-in via the given provider.
  ///
  /// [auto] marks the ONE automatic attempt of a signed-out stretch, fired without a tap.
  /// It selects the Credential Manager BOTTOM SHEET as the first surface (Google's SIWG order).
  /// A pill tap is `auto: false` and goes straight to the button flow.
  /// Google's reasons for the button are why the user taps — dismissed sheet, no accounts, re-auth.
  Future<AuthResult> signInWith(AuthProvider provider, {bool auto = false});

  /// Declares every sign-in attempt started so far ABANDONED.
  ///
  /// Credential Manager can sit on its callback for minutes — observed 13 min on device.
  /// A late resolve is discarded before ANY side effect: no token exchange, no emit, no analytics.
  /// Called by the stall guard before it frees the UI -> a revived zombie cannot race its replacement.
  void abandonPendingSignIn();

  /// Update the display name — the trimmed [name] goes to the Worker, then out on [authStateChanges].
  /// Throws on failure so the caller can surface it.
  Future<void> updateDisplayName(String name);

  /// Sign out the current user.
  Future<void> signOut();

  /// Permanently delete the account server-side — revoke any live mandate, drop all data, clear session.
  /// Throws on failure -> the account is NOT deleted, the session stays, the caller surfaces the error.
  Future<void> deleteAccount();
}
