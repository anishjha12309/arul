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

  Future<AuthResult> signIn(AuthProvider provider) =>
      ref.read(authServiceProvider).signInWith(provider);

  Future<void> updateDisplayName(String name) =>
      ref.read(authServiceProvider).updateDisplayName(name);

  Future<void> signOut() => ref.read(authServiceProvider).signOut();

  /// Permanently deletes the account server-side and clears the session.
  /// Throws on failure (account intact) so the UI can surface the error.
  Future<void> deleteAccount() => ref.read(authServiceProvider).deleteAccount();
}
