import 'dart:async';

import 'package:flutter/foundation.dart';

import 'sign_in_outcome.dart';

/// The auth providers the app supports — never put provider-specific logic in widgets or the router.
enum AuthProvider { google }

sealed class AuthResult {
  const AuthResult();
}

final class AuthSuccess extends AuthResult {
  const AuthSuccess({required this.userId});
  final String userId;
}

final class AuthCancelled extends AuthResult {
  const AuthCancelled({this.outcome = SignInOutcome.backedOutQuick});

  /// What the attempt actually did, so the screen can say something TRUE about it.
  ///
  /// Defaults to the plain retry line: the quiet internal drops (a zombie attempt the stall guard
  /// already abandoned) have no evidence to classify from and must claim nothing.
  final SignInOutcome outcome;
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

  /// Google's surface came up ([SignInSignal.surfaceShown]) or an attempt ended any way at all
  /// ([SignInSignal.settled]) -> the come-back reminder's arm and disarm, fed without a new member
  /// on [AuthService].
  static final StreamController<SignInSignal> signals =
      StreamController<SignInSignal>.broadcast(sync: true);
}

enum SignInSignal { surfaceShown, settled }

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
  ///
  /// [returned] marks the automatic attempt a RETURN to the wall re-armed, as opposed to the one a
  /// cold start fires. Analytics only — it changes no surface and no order, it only renames the
  /// sheet on this attempt's events (`sheet_return`) so the two populations stay separable.
  ///
  /// [reconnected] marks the automatic attempt a RECONNECT re-armed — the link that killed the last
  /// attempt came back. Analytics only, exactly like [returned], which WINS if both are somehow
  /// set: the sheet is still the first surface, only its name changes (`sheet_reconnect`), so the
  /// one re-arm a dead link earns can be priced against the cold-start sheet.
  ///
  /// [reopened] marks the picker the guard puts back after Google's add-account flow handed the
  /// user back with nothing chosen. Analytics only, like [returned]: it is always a BUTTON-flow
  /// attempt (`auto: false`) and only renames that picker (`button_after_add_account`).
  Future<AuthResult> signInWith(
    AuthProvider provider, {
    bool auto = false,
    bool returned = false,
    bool reconnected = false,
    bool reopened = false,
  });

  /// Declares every sign-in attempt started so far ABANDONED.
  ///
  /// Credential Manager can sit on its callback for minutes — observed 13 min on device.
  /// A late resolve is discarded before ANY side effect: no token exchange, no emit, no analytics.
  /// Called by the stall guard before it frees the UI -> a revived zombie cannot race its replacement.
  void abandonPendingSignIn();

  /// Update the display name — the trimmed [name] goes to the Worker, then out on [authStateChanges].
  /// Throws on failure so the caller can surface it.
  Future<void> updateDisplayName(String name);

  Future<void> signOut();

  /// Permanently delete the account server-side — revoke any live mandate, drop all data, clear session.
  /// Throws on failure -> the account is NOT deleted, the session stays, the caller surfaces the error.
  Future<void> deleteAccount();
}
