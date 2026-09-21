import 'dart:async';

import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../app/l10n/app_localizations.dart';
import '../../../core/providers/locale_provider.dart';
import '../../../core/providers/shared_preferences_provider.dart';
import '../../auth/providers/auth_providers.dart';
import '../../premium/domain/trial_nudge.dart';
import '../../premium/providers/entitlement_provider.dart';
import '../data/notification_service.dart';
import '../domain/notification_settings.dart';

part 'notification_providers.g.dart';

/// The [NotificationService], overridden in `main()` with the instance initialised there.
///
/// Created before `runApp` -> a notification tap that LAUNCHED the app has a live handler on replay.
@Riverpod(keepAlive: true)
NotificationService notificationService(Ref ref) => throw UnimplementedError(
  'notificationServiceProvider must be overridden in main()',
);

/// Persisted notification preferences (SharedPreferences-backed).
@Riverpod(keepAlive: true)
class NotificationSettingsNotifier extends _$NotificationSettingsNotifier {
  @override
  NotificationSettings build() =>
      NotificationSettings.fromPrefs(ref.read(sharedPreferencesProvider));

  Future<void> _persist(NotificationSettings next) async {
    state = next;
    await next.save(ref.read(sharedPreferencesProvider));
  }

  /// Turns the feature on or off; turning on prompts for the OS permission and returns the grant.
  /// So the UI can point a user who declined at system settings.
  Future<bool> setMasterEnabled(bool enabled) async {
    if (enabled) {
      final granted = await ref
          .read(notificationServiceProvider)
          .requestPermissions();
      // A denied prompt must leave the toggle OFF -> persist ON only on a real grant.
      // Otherwise the UI claims reminders are active while Android drops every one.
      await _persist(state.copyWith(masterEnabled: granted));
      return granted;
    }
    await _persist(state.copyWith(masterEnabled: false));
    return false;
  }

  /// Reconciles the persisted opt-in with the real OS permission, revocable at any time.
  ///
  /// Only an explicit "denied" flips the toggle off — null leaves state untouched.
  /// So a flaky OEM query can never wipe a valid opt-in.
  Future<void> syncWithSystem() async {
    if (!state.masterEnabled) return;
    final allowed = await ref
        .read(notificationServiceProvider)
        .areNotificationsEnabled();
    if (allowed == false) {
      await _persist(state.copyWith(masterEnabled: false));
    }
  }

  /// The single time-of-day every reminder fires at.
  Future<void> setReminderTime(int hour, int minute) =>
      _persist(state.copyWith(reminderHour: hour, reminderMinute: minute));
}

/// Side-effecting bootstrap — re-arms the local schedule on every settings change, and once at start.
///
/// Watched from the ROOT widget so it stays alive for the app's lifetime.
/// The SINGLE place that drives scheduling — the notifier's mutators only persist state.
/// So there is exactly one path from "settings changed" to "alarms re-armed", and no drift.
/// Festival reminders are one-shot alarms -> the startup run is what carries the schedule forward.
@Riverpod(keepAlive: true)
Future<void> notificationBootstrap(Ref ref) async {
  final settings = ref.watch(notificationSettingsProvider);
  final service = ref.read(notificationServiceProvider);

  if (!settings.masterEnabled) {
    await service.cancelAllPending();
  } else {
    await service.applySettings(settings);
  }

  // AFTER either branch, because both cancel every pending notification — including this one.
  //
  // The unfinished-trial reminder is NOT a devotional reminder and the master toggle does not own
  // it: it is one follow-up to a payment the user started themselves. Gating it on that toggle
  // would make it dead code, since it defaults OFF and the people who abandon a trial are mostly
  // fresh installs. Its gate is the OS permission alone — `scheduleTrialReminder` refuses without
  // it, and NOTHING here ever asks for it.
  //
  // Re-armed at its PERSISTED instant, never a fresh six hours: recomputing from now would push the
  // reminder further out on every launch, so the people who open the app most would never see it.
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
