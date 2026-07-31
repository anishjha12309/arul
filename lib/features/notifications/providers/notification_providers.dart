import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/providers/shared_preferences_provider.dart';
import '../data/notification_service.dart';
import '../domain/notification_settings.dart';

part 'notification_providers.g.dart';

/// The [NotificationService]. Overridden in `main()` with the instance whose
/// `initialize()` was kicked off there — the same shape as
/// `sharedPreferencesProvider`, and for the same reason: the service is created
/// before `runApp` so a notification tap that LAUNCHED the app has a live
/// handler by the time the plugin replays it.
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

  /// Turns the feature on/off. When turning on, prompts for the OS notification
  /// permission and returns whether it was granted, so the UI can point the user
  /// at system settings if they declined.
  Future<bool> setMasterEnabled(bool enabled) async {
    if (enabled) {
      final granted = await ref
          .read(notificationServiceProvider)
          .requestPermissions();
      // ON is persisted only when the OS actually granted the permission. A
      // denied prompt must leave the toggle off, or the UI claims reminders are
      // active while Android drops every one of them.
      await _persist(state.copyWith(masterEnabled: granted));
      return granted;
    }
    await _persist(state.copyWith(masterEnabled: false));
    return false;
  }

  /// Reconciles the persisted opt-in with the real OS permission, which the user
  /// can revoke in system settings at any time.
  ///
  /// Only an explicit "denied" flips the toggle off — an unknown answer (null)
  /// leaves state untouched, so a flaky OEM query can never wipe a valid opt-in.
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

/// Side-effecting bootstrap: re-arms the local schedule whenever settings
/// change, and once on startup.
///
/// Watched from the root widget so it stays alive for the app's lifetime. This
/// is the SINGLE place that drives scheduling — the notifier's mutators only
/// persist state, so there is exactly one path from "settings changed" to
/// "alarms re-armed" and no way for the two to drift.
///
/// The startup run is not optional: the festival reminders are one-shot alarms,
/// so re-arming on launch is what carries the schedule past each festival and
/// into the next.
@Riverpod(keepAlive: true)
Future<void> notificationBootstrap(Ref ref) async {
  final settings = ref.watch(notificationSettingsProvider);
  final service = ref.read(notificationServiceProvider);

  if (!settings.masterEnabled) {
    await service.cancelAll();
    return;
  }

  await service.applySettings(settings);
}
