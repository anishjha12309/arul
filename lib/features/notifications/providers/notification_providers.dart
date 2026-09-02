import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/providers/shared_preferences_provider.dart';
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
    await service.cancelAll();
    return;
  }

  await service.applySettings(settings);
}
