import 'dart:async';

import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../app/l10n/app_localizations.dart';
import '../../../core/providers/locale_provider.dart';
import '../../../core/providers/shared_preferences_provider.dart';
import '../../auth/providers/auth_providers.dart';
import '../../premium/domain/trial_nudge.dart';
import '../../premium/providers/entitlement_provider.dart';
import '../data/notification_service.dart';

part 'notification_providers.g.dart';

/// The [NotificationService], overridden in `main()` with the instance initialised there.
///
/// Created before `runApp` -> a notification tap that LAUNCHED the app has a live handler on replay.
@Riverpod(keepAlive: true)
NotificationService notificationService(Ref ref) => throw UnimplementedError(
  'notificationServiceProvider must be overridden in main()',
);

/// Re-arms the unfinished-trial reminder once per launch, watched from the ROOT widget.
///
/// Re-armed at its PERSISTED instant, never a fresh six hours: recomputing from now would push the
/// reminder further out on every launch, so the people who open the app most would never see it.
/// Its only gate is the OS permission — `scheduleTrialReminder` refuses without it, and NOTHING here
/// ever asks for it.
@Riverpod(keepAlive: true)
Future<void> notificationBootstrap(Ref ref) async {
  final service = ref.read(notificationServiceProvider);
  final prefs = ref.read(sharedPreferencesProvider);
  final due = TrialNudge.pendingReminder(prefs, DateTime.now());
  if (due != null) {
    // No BuildContext here — a boot re-arm has no widget tree. `lookupAppLocalizations` is the
    // generated SYNCHRONOUS lookup, fed the same locale the app resolved for its UI.
    final l10n = lookupAppLocalizations(ref.read(localeProvider));
    await service.scheduleTrialReminder(
      due: due,
      title: l10n.trialReminderTitle,
      body: l10n.trialReminderBody,
    );
    // The marker is written when the UPI app takes over, so it can outlive an approval the app
    // never saw. Entitlement is LAZY — nothing reads it until a gated tap or the feed row — and a
    // launch that lands on Ringtones or Settings builds neither. Ask now, AFTER the re-arm: a
    // premium answer resolves the marker and cancels what was just armed. Behind the auth seed, or
    // the read settles as signed-out before the stored session is known. Never awaited, never
    // allowed to matter: signed out or offline simply leaves the reminder as it was.
    unawaited(() async {
      try {
        await ref.read(authServiceProvider).initialized;
        await ref.read(entitlementProvider.future);
      } catch (_) {}
    }());
  }
}
