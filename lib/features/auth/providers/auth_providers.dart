import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/analytics/analytics_provider.dart';
import '../../../core/api/api_client.dart';
import '../../../core/crash/crash_provider.dart';
import '../../referral/providers/referral_providers.dart';
import '../data/api_auth_service.dart';
import '../domain/auth_service.dart';

part 'auth_providers.g.dart';

// ─── Infrastructure ───────────────────────────────────────────────────────────

@Riverpod(keepAlive: true)
ApiClient apiClient(Ref ref) => ApiClient();

@Riverpod(keepAlive: true)
AuthService authService(Ref ref) => ApiAuthService(
  apiClient: ref.watch(apiClientProvider),
  analytics: ref.watch(analyticsServiceProvider),
  crash: ref.watch(crashReporterProvider),
  installReferrer: ref.watch(installReferrerServiceProvider),
);

// ─── Auth state stream ────────────────────────────────────────────────────────

/// Emits the latest [AuthUserState]. Starts as [AsyncLoading] until the stored-
/// token check in [ApiAuthService] fires its initial event (almost immediate).
@Riverpod(keepAlive: true)
Stream<AuthUserState> authStateStream(Ref ref) =>
    ref.watch(authServiceProvider).authStateChanges;

// ─── Auth controller (actions) ────────────────────────────────────────────────

/// Exposes sign-in / sign-out actions. Consumers read state from
/// [authStateStreamProvider] and call methods on this notifier.
@Riverpod(keepAlive: true)
class AuthController extends _$AuthController {
  @override
  FutureOr<void> build() {}

  /// The sign-in currently in flight, if any. Google's account picker is a
  /// system Activity, so two overlapping `signInWith` calls put TWO sheets on
  /// screen — one of which appears, hangs and vanishes. That shipped once
  /// (2026-08-11) and must not again: every caller goes through here.
  Future<AuthResult>? _inFlight;

  /// Whether the ONE automatic sign-in of the CURRENT signed-out stretch has
  /// been spent. Re-armed by [signOut] / [deleteAccount] — scoping this to the
  /// process instead meant that after logging out the sign-in screen asked for
  /// an attempt it could never get, and no picker appeared (fixed 2026-08-11).
  ///
  /// A session that dies on its own (refresh token expired → 401) needs no
  /// re-arm: that is detected during the startup seed, before the splash fires
  /// the auto-launch, so the flag is still false when it matters.
  bool _autoLaunched = false;

  /// Starts a sign-in, or joins the one already running.
  ///
  /// Safe to call from a button: a user who taps the pill while a sheet is
  /// already up gets that sheet's result, not a second sheet.
  Future<AuthResult> signIn(AuthProvider provider) {
    final existing = _inFlight;
    if (existing != null) return existing;
    final future = ref
        .read(authServiceProvider)
        .signInWith(provider)
        .whenComplete(() => _inFlight = null);
    _inFlight = future;
    return future;
  }

  /// The automatic sign-in, fired ONCE per process by whichever screen gets
  /// there first — the splash the moment it knows there is no stored session,
  /// or the sign-in screen's first frame if the splash did not.
  ///
  /// Returns null once that single attempt is spent and settled, which is the
  /// signal to show the retry pill and stay put. Without this a cancelled sheet
  /// would be re-launched the instant the splash routed to sign-in, and the
  /// user could never get off the screen.
  Future<AuthResult>? autoSignIn(AuthProvider provider) {
    if (_autoLaunched) return _inFlight;
    _autoLaunched = true;
    return signIn(provider);
  }

  Future<void> updateDisplayName(String name) =>
      ref.read(authServiceProvider).updateDisplayName(name);

  Future<void> signOut() async {
    await ref.read(authServiceProvider).signOut();
    _autoLaunched = false;
  }

  /// Permanently deletes the account server-side and clears the session.
  /// Throws on failure (account intact) so the UI can surface the error.
  ///
  /// The re-arm is deliberately AFTER the await: a failed delete leaves the
  /// user signed in, and re-arming there would hand a picker to a session that
  /// is still perfectly alive.
  Future<void> deleteAccount() async {
    await ref.read(authServiceProvider).deleteAccount();
    _autoLaunched = false;
  }
}
