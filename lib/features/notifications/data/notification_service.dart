import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_10y.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../../../theme/arul_tokens.dart';

/// Owns the [FlutterLocalNotificationsPlugin]: both channels and the app's one-off local posts.
class NotificationService {
  NotificationService({
    required this._prefs,
    FlutterLocalNotificationsPlugin? plugin,
  }) : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final SharedPreferences _prefs;
  final FlutterLocalNotificationsPlugin _plugin;

  /// Ids below this belonged to the retired devotional reminders (weekly 1000+, festivals 2000+).
  /// An upgraded phone can still hold them armed -> [_retireLegacyReminders] cancels them by id.
  static const _legacyReminderIdCeiling = 3000;

  /// The unfinished-trial reminder. One at a time, so ONE id.
  static const _trialReminderId = 3000;

  /// The come-back reminder (Android 12L and below). Once per install, so ONE id.
  static const _comeBackId = 3001;

  /// Monochrome status-bar silhouette. Android tints it -> never the launcher icon, it renders white.
  static const _icon = 'ic_notification';

  static const _largeIcon = 'ic_notification_large';

  /// Arul gold — tints the app name and accent line so the post reads as ours.
  ///
  /// A boot receiver can drive this class with no Flutter UI alive at all, which is fine: the
  /// token is a compile-time const and needs no BuildContext, so the one palette stays the source.
  static const _accent = ArulTokens.gold;

  static const updatesChannelId = 'arul_updates_v1';

  /// Fallback until [setUpdatesChannelName] supplies the user's language. Name and description ARE
  /// mutable (importance may only be lowered, sound never changes), so renaming costs one Binder call.
  static const _defaultUpdatesChannelName = 'Updates from Arul';

  String _updatesChannelName = _defaultUpdatesChannelName;

  /// The heads-up channel campaigns post to (ArulMessagingService), when this phone has it.
  static const campaignChannelId = 'arul_campaigns_v1';

  static const _defaultCampaignChannelName = 'New wallpapers and offers';

  String _campaignChannelName = _defaultCampaignChannelName;

  /// The importance [campaignChannelId] was created at, or `Importance.none` when it never will be.
  /// Absent until decided — a failed read retries next launch.
  static const campaignChannelPrefKey = 'arul_campaign_channel_importance';

  /// Null until [initialize] settles it; `Importance.none` means the channel was never created.
  Importance? _campaignImportance;

  /// Superseded channels, deleted on init -> no stale duplicates in the system notification settings.
  /// The two devotional-reminder channels went with the reminders themselves.
  static const _legacyChannelIds = <String>[
    'arul_devotional_weekly_v1',
    'arul_festivals_v1',
  ];

  bool _initialized = false;

  /// In-flight or completed initialisation -> concurrent callers share ONE setup, never race two.
  /// Plugin init is deferred off startup, so the warm-up and a bootstrap call can both land at once.
  Future<void>? _initFuture;

  AndroidFlutterLocalNotificationsPlugin? get _android => _plugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >();

  /// Set once the router exists. Null until then — an early tap just opens the app.
  void Function()? onOpenTrialReminder;

  /// Payload marking [_trialReminderId].
  static const trialReminderPayload = 'arul_trial_reminder';

  /// Payload marking [_comeBackId]. A tap needs no route: opening the app is the sign-in.
  static const comeBackPayload = 'arul_come_back';

  /// One-time setup: timezone database, plugin init, channel creation.
  /// Prompts for NO permission. Single-flight via [_initFuture].
  Future<void> initialize() => _initFuture ??= _doInitialize();

  Future<void> _doInitialize() async {
    // The IANA tz parse is synchronous UI-isolate work. Push registration calls this the instant the
    // auth seed settles, ahead of the splash's own continuation -> parse only after the plugin's
    // Binder hop has yielded, so a signed-out launch asks Google for the sheet first.
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings(_icon),
      ),
      onDidReceiveNotificationResponse: _onTap,
    );
    tzdata.initializeTimeZones();
    final tzFuture = _applyLocalTimezone();

    final android = _android;
    // Channel creates and legacy deletes are independent Binder round-trips -> fire them together.
    await Future.wait<void>([
      tzFuture,
      if (android != null) ...[
        android.createNotificationChannel(_updatesChannel()),
        for (final id in _legacyChannelIds)
          android.deleteNotificationChannel(channelId: id),
      ],
    ]);

    if (android != null) await _settleCampaignChannel(android);
    _initialized = true;
    await _retireLegacyReminders();
  }

  /// What [campaignChannelId] is created at, given the user's level on [updatesChannelId] — the
  /// channel campaigns used before. Null: do not create it, so a blocked choice stays blocked.
  @visibleForTesting
  static Importance? campaignImportanceFor(Importance? updates) =>
      switch (updates) {
        Importance.none => null,
        Importance.min || Importance.low => updates,
        _ => Importance.high,
      };

  /// Decides the campaign channel ONCE, then re-creates it at that level on every launch like
  /// [updatesChannelId], which only refreshes its name: Android never raises an existing channel.
  Future<void> _settleCampaignChannel(
    AndroidFlutterLocalNotificationsPlugin android,
  ) async {
    try {
      var importance = _storedCampaignImportance();
      if (importance == null) {
        final channels = await android.getNotificationChannels() ?? const [];
        final updates = channels
            .where((c) => c.id == updatesChannelId)
            .firstOrNull
            ?.importance;
        importance = campaignImportanceFor(updates) ?? Importance.none;
        await _prefs.setInt(campaignChannelPrefKey, importance.value);
      }
      _campaignImportance = importance;
      if (importance != Importance.none) {
        await android.createNotificationChannel(_campaignChannel(importance));
      }
    } on PlatformException catch (e) {
      debugPrint('[NotificationService] campaign channel not settled: $e');
    }
  }

  Importance? _storedCampaignImportance() {
    final stored = _prefs.getInt(campaignChannelPrefKey);
    if (stored == null) return null;
    return Importance.values.firstWhere(
      (i) => i.value == stored,
      orElse: () => Importance.high,
    );
  }

  Future<void> _retireLegacyReminders() async {
    try {
      final pending = await _plugin.pendingNotificationRequests();
      for (final n in pending) {
        if (n.id < _legacyReminderIdCeiling) await _plugin.cancel(id: n.id);
      }
    } on PlatformException catch (e) {
      debugPrint('[NotificationService] legacy reminder cancel failed: $e');
    }
  }

  AndroidNotificationChannel _updatesChannel() => AndroidNotificationChannel(
    updatesChannelId,
    _updatesChannelName,
    description: 'New wallpapers, ringtones and offers',
    importance: Importance.defaultImportance,
  );

  /// The system default sound: a channel's sound is fixed the moment it is created.
  AndroidNotificationChannel _campaignChannel(Importance importance) =>
      AndroidNotificationChannel(
        campaignChannelId,
        _campaignChannelName,
        description: 'New wallpapers, ringtones and offers',
        importance: importance,
      );

  /// Rename the campaign channel into the user's language, and on every later language change.
  ///
  /// Re-creating with the same id UPDATES the name; only importance (downward) and the sound are
  /// pinned. Cheap enough to call whenever the locale settles, and a no-op before [initialize].
  Future<void> setUpdatesChannelName(String name) async {
    if (name.isEmpty || name == _updatesChannelName) return;
    _updatesChannelName = name;
    if (!_initialized) return;
    try {
      await _android?.createNotificationChannel(_updatesChannel());
    } on PlatformException catch (e) {
      debugPrint('[NotificationService] updates channel rename failed: $e');
    }
  }

  /// [setUpdatesChannelName] for [campaignChannelId]; never creates a channel the user's choice skipped.
  Future<void> setCampaignChannelName(String name) async {
    if (name.isEmpty || name == _campaignChannelName) return;
    _campaignChannelName = name;
    final importance = _campaignImportance;
    if (!_initialized || importance == null || importance == Importance.none) {
      return;
    }
    try {
      await _android?.createNotificationChannel(_campaignChannel(importance));
    } on PlatformException catch (e) {
      debugPrint('[NotificationService] campaign channel rename failed: $e');
    }
  }

  /// Resolve the device IANA zone → `tz.local`. Independent of plugin init, so it overlaps it.
  /// An unresolvable zone leaves `tz.local` as UTC; a one-off is armed from an absolute instant, so it
  /// still fires on time.
  Future<void> _applyLocalTimezone() async {
    try {
      final info = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(info.identifier));
    } catch (_) {
      // Deliberately swallowed — a wrong hour beats no reminders.
    }
  }

  /// Routes a tap on a local post. Anything unrecognised, or a null handler before the app is up,
  /// falls through to opening the app.
  void _onTap(NotificationResponse response) {
    if (response.payload == trialReminderPayload) onOpenTrialReminder?.call();
  }

  /// Whether the OS currently allows posting — it can be revoked in settings at any time.
  ///
  /// Null means UNKNOWN, never denied.
  Future<bool?> areNotificationsEnabled() =>
      _android?.areNotificationsEnabled() ?? Future.value(null);

  NotificationDetails _details({required String body}) => NotificationDetails(
    android: AndroidNotificationDetails(
      updatesChannelId,
      _updatesChannelName,
      icon: _icon,
      largeIcon: const DrawableResourceAndroidBitmap(_largeIcon),
      color: _accent,
      // Expanded layout -> the full body reads without pulling the shade open on a truncated line.
      styleInformation: BigTextStyleInformation(body),
    ),
  );

  /// Arms the ONE unfinished-trial reminder for [due]. False when nothing was scheduled.
  Future<bool> scheduleTrialReminder({
    required DateTime due,
    required String title,
    required String body,
  }) async {
    if (!_initialized) await initialize();
    if (await areNotificationsEnabled() != true) return false;
    final when = tz.TZDateTime.from(due, tz.local);
    if (!when.isAfter(tz.TZDateTime.now(tz.local))) return false;
    try {
      await _plugin.zonedSchedule(
        id: _trialReminderId,
        title: title,
        body: body,
        scheduledDate: when,
        notificationDetails: _details(body: body),
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        payload: trialReminderPayload,
      );
      return true;
    } catch (e) {
      debugPrint('[TrialNudge] reminder not scheduled: $e');
      return false;
    }
  }

  Future<void> cancelTrialReminder() async {
    if (!_initialized) await initialize();
    await _plugin.cancel(id: _trialReminderId);
  }

  /// Arms the ONE come-back reminder for [due], [picturePath] as its big picture. False when nothing
  /// was scheduled. Never asks for the permission: Android 12 and below post without one, and the
  /// caller arms it there only.
  Future<bool> scheduleComeBack({
    required DateTime due,
    required String title,
    required String body,
    String? picturePath,
  }) async {
    if (!_initialized) await initialize();
    if (await areNotificationsEnabled() != true) return false;
    final when = tz.TZDateTime.from(due, tz.local);
    if (!when.isAfter(tz.TZDateTime.now(tz.local))) return false;
    try {
      await _plugin.zonedSchedule(
        id: _comeBackId,
        title: title,
        body: body,
        scheduledDate: when,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            updatesChannelId,
            _updatesChannelName,
            icon: _icon,
            largeIcon: const DrawableResourceAndroidBitmap(_largeIcon),
            color: _accent,
            styleInformation: picturePath == null
                ? BigTextStyleInformation(body)
                : BigPictureStyleInformation(
                    FilePathAndroidBitmap(picturePath),
                    contentTitle: title,
                    summaryText: body,
                    hideExpandedLargeIcon: true,
                  ),
          ),
        ),
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        payload: comeBackPayload,
      );
      return true;
    } catch (e) {
      debugPrint('[ComeBack] reminder not scheduled: $e');
      return false;
    }
  }

  Future<void> cancelComeBack() async {
    if (!_initialized) await initialize();
    await _plugin.cancel(id: _comeBackId);
  }
}
