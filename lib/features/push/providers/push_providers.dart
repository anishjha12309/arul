import 'dart:async';

import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../app/l10n/app_localizations.dart';
import '../../../core/analytics/analytics_provider.dart';
import '../../../core/crash/crash_provider.dart';
import '../../../core/providers/locale_provider.dart';
import '../../../core/providers/shared_preferences_provider.dart';
import '../../auth/providers/auth_providers.dart';
import '../../notifications/providers/notification_providers.dart';
import '../data/push_permission.dart';
import '../data/push_registration.dart';

part 'push_providers.g.dart';

/// The campaign-push registry writer. One per app, kept alive for the whole process.
@Riverpod(keepAlive: true)
PushRegistration pushRegistration(Ref ref) {
  final registration = PushRegistration(
    apiClient: ref.watch(apiClientProvider),
    crash: ref.watch(crashReporterProvider),
    // Read on every call, not captured: a language change re-posts the row, which is what makes the
    // "By language" audience mean the language the phone is actually reading.
    appLanguage: () => ref.read(localeProvider).languageCode,
  );
  ref.onDispose(registration.dispose);
  return registration;
}

/// The one-time `POST_NOTIFICATIONS` prompt.
@Riverpod(keepAlive: true)
PushPermission pushPermission(Ref ref) => PushPermission(
  prefs: ref.watch(sharedPreferencesProvider),
  analytics: ref.watch(analyticsServiceProvider),
  crash: ref.watch(crashReporterProvider),
);

/// Keeps the campaign channel's NAME in the user's language.
///
/// Watched at the root so it runs on the first frame of every launch and again on every language
/// change. The channel itself is created by `NotificationService.initialize()` with an English name,
/// so it exists from the very first launch whatever happens here — this only renames it.
/// `AppLocalizations.delegate.load` resolves the string without a BuildContext, which matters:
/// nothing in the notification stack may depend on one (a boot receiver drives it with no UI alive).
@Riverpod(keepAlive: true)
Future<void> pushChannelName(Ref ref) async {
  final locale = ref.watch(localeProvider);
  final service = ref.watch(notificationServiceProvider);
  final l10n = await AppLocalizations.delegate.load(locale);
  await service.setUpdatesChannelName(l10n.pushChannelName);
}

/// Registers this phone, once per launch, and re-registers when the language or the token moves.
///
/// Deliberately NOT tied to a screen: it watches the auth stream, so it fires on a cold start that
/// already had a session AND right after a fresh sign-in, which are the two moments a row can appear
/// or change hands. Never awaited by anything on screen — a registration that fails costs this phone
/// the next campaign and nothing else.
@Riverpod(keepAlive: true)
void pushBootstrap(Ref ref) {
  // The stream is a broadcast controller that does NOT replay its last event, so awaiting it can
  // hang forever — watch it for the re-run and read the synchronous `currentState`, exactly as the
  // entitlement provider does for the same reason.
  ref.watch(authStateStreamProvider);
  // Watched, not read: a language change re-runs this and re-posts the row through the same
  // debounce, which is what keeps the "By language" audience honest.
  ref.watch(localeProvider);
  if (!ref.read(authServiceProvider).currentState.isAuthenticated) return;
  final registration = ref.watch(pushRegistrationProvider);
  registration.listenForTokenRefresh();
  unawaited(registration.register());
}
