import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../domain/devotional_event.dart';
import '../domain/notification_settings.dart';

/// What [NotificationService.audit] found actually armed on the device.
///
/// [festivalsArmed] short of [festivalsExpected] is NOT a defect — a festival out of dates is skipped.
/// It is surfaced because that skip is otherwise completely silent.
class NotificationAudit {
  const NotificationAudit({
    required this.weeklyArmed,
    required this.weeklyExpected,
    required this.festivalsArmed,
    required this.festivalsExpected,
    required this.titles,
  });

  final int weeklyArmed;
  final int weeklyExpected;
  final int festivalsArmed;
  final int festivalsExpected;

  /// Titles of everything armed, for the QA card's detail list.
  final List<String> titles;

  int get totalArmed => weeklyArmed + festivalsArmed;

  /// True when every reminder the tables define is armed.
  bool get complete =>
      weeklyArmed == weeklyExpected && festivalsArmed == festivalsExpected;

  /// Festivals the scheduler skipped for want of a future date.
  int get skippedFestivals => festivalsExpected - festivalsArmed;
}

/// Owns the [FlutterLocalNotificationsPlugin] and turns [NotificationSettings] into local alarms.
///
/// The REMINDERS are fully on-device: no network, no server, nothing leaves the phone.
/// This class also creates the CAMPAIGN channel ([updatesChannelId]) but never posts to it — FCM shows
/// those itself, and the channel has to exist before a message arrives (docs/push.md).
///
///  * **Weekly** ([weeklyDevotionalDays]) — a native recurring alarm, armed once, repeated by the OS;
///  * **Festivals** ([festivalEvents]) — one-shot; a lunisolar festival has no recurrence rule.
///
/// So festivals are re-armed on every launch by `notificationBootstrapProvider`.
/// Once the table runs out they are simply skipped (see [FestivalEvent]).
class NotificationService {
  NotificationService([FlutterLocalNotificationsPlugin? plugin])
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;

  // Ids are stable and non-overlapping, derived from the event INDEX rather than a hash.
  // That keeps them small and legible in `adb shell dumpsys notification`.
  // Reordering a list reshuffles ids — harmless, since applySettings cancels everything first.
  // The KEYS are the identity, never these numbers.
  static const _weeklyIdBase = 1000;
  static const _festivalIdBase = 2000;

  /// The unfinished-trial reminder. One at a time, so ONE id, clear of both ranges above.
  static const _trialReminderId = 3000;
  static const _testId = 9999;

  /// Monochrome status-bar silhouette. Android tints it -> never the launcher icon, it renders white.
  static const _icon = 'ic_notification';

  /// The coloured brand mark, shown beside the text.
  static const _largeIcon = 'ic_notification_large';

  /// Whether `res/raw/arul_bell.mp3` is present in the build.
  ///
  /// FALSE deliberately — referencing a missing raw resource fails CHANNEL CREATION outright.
  /// That takes every reminder down, not just its sound -> reminders use the device's default tone.
  /// Switching it on is this flag plus the channel-id bump a new sound needs (docs/notifications.md).
  static const bool _kChimeBundled = false;

  static const _sound = RawResourceAndroidNotificationSound('arul_bell');
  static AndroidNotificationSound? get _chime => _kChimeBundled ? _sound : null;

  /// Arul gold (`ArulTokens.gold`) — tints the app name and accent line so the post reads as ours.
  ///
  /// A boot receiver can drive this class with no Flutter UI alive at all.
  /// So it must not depend on anything needing a BuildContext -> hard-coded, never imported.
  static const _accent = Color(0xFFD4A017);

  // A channel's SOUND is immutable once it exists on a device -> the `_v1` suffix is load-bearing.
  // Bundling the chime later needs a NEW id, with the old one added to _legacyChannelIds.
  static const _weeklyChannelId = 'arul_devotional_weekly_v1';
  static const _weeklyChannelName = 'Weekly devotional reminders';
  static const _festivalChannelId = 'arul_festivals_v1';
  static const _festivalChannelName = 'Festival reminders';

  /// The CMS campaign channel (docs/push.md). Created by THIS class even though nothing here ever
  /// posts to it: FCM shows those notifications itself, and the id in the payload has to already
  /// exist on the device or FCM silently falls back to the manifest's default channel.
  ///
  /// Created at EVERY launch, never at opt-in, and that is the point on Android 8–12: those phones
  /// have no runtime permission, so the channel IS the user's control — and a phone that upgrades to
  /// 13 later is auto-granted only if a channel already exists and notifications were not disabled.
  /// **The id is immutable once a device has seen it** — a new one appears as a second, empty toggle
  /// in system settings. Getting it right the first time is the whole reason for the `_v1` suffix.
  static const updatesChannelId = 'arul_updates_v1';

  /// Fallback until [setUpdatesChannelName] supplies the user's language. Name and description ARE
  /// mutable (importance may only be lowered, sound never changes), so renaming costs one Binder call.
  static const _defaultUpdatesChannelName = 'Updates from Arul';

  String _updatesChannelName = _defaultUpdatesChannelName;

  /// Superseded channels, deleted on init -> no stale duplicates in the system notification settings.
  static const _legacyChannelIds = <String>[];

  bool _initialized = false;

  /// In-flight or completed initialisation -> concurrent callers share ONE setup, never race two.
  /// Plugin init is deferred off startup, so the warm-up and a bootstrap call can both land at once.
  Future<void>? _initFuture;

  AndroidFlutterLocalNotificationsPlugin? get _android => _plugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >();

  /// Set once the router exists -> a notification tap opens the feed on the right category.
  /// Null until then — an early tap just opens the app, which is the correct fallback.
  void Function(String category)? onOpenCategory;

  /// Tapped the unfinished-trial reminder — the paywall, not a category.
  void Function()? onOpenTrialReminder;

  /// Payload marking [_trialReminderId], distinguishable from every category slug.
  static const trialReminderPayload = 'arul_trial_reminder';

  /// One-time setup: timezone database, plugin init, channel creation.
  /// Prompts for NO permission — that is opt-in ([requestPermissions]). Single-flight via [_initFuture].
  Future<void> initialize() => _initFuture ??= _doInitialize();

  Future<void> _doInitialize() async {
    // The IANA tz parse is synchronous UI-isolate work -> deferred here, it never gates first frame.
    // Zone resolution and plugin init are independent -> overlap them, never await in series.
    tzdata.initializeTimeZones();
    final tzFuture = _applyLocalTimezone();

    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings(_icon),
      ),
      onDidReceiveNotificationResponse: _onTap,
    );

    final android = _android;
    // Channel creates and legacy deletes are independent Binder round-trips -> fire them together.
    await Future.wait<void>([
      tzFuture,
      if (android != null) ...[
        android.createNotificationChannel(
          AndroidNotificationChannel(
            _weeklyChannelId,
            _weeklyChannelName,
            description: 'The weekly devotional day',
            importance: Importance.high,
            sound: _chime,
          ),
        ),
        android.createNotificationChannel(
          AndroidNotificationChannel(
            _festivalChannelId,
            _festivalChannelName,
            description:
                'Pongal, Deepavali, Navaratri and other Tamil festivals',
            importance: Importance.high,
            sound: _chime,
          ),
        ),
        android.createNotificationChannel(_updatesChannel()),
        for (final id in _legacyChannelIds)
          android.deleteNotificationChannel(channelId: id),
      ],
    ]);

    _initialized = true;
  }

  /// The campaign channel. `defaultImportance`, not high: these are ours to send, not the user's to
  /// expect, so they belong in the shade rather than as a heads-up banner over whatever they are
  /// doing. No custom sound — referencing the absent `arul_bell` raw resource fails channel creation
  /// outright, which would take the reminder channels down with it.
  AndroidNotificationChannel _updatesChannel() => AndroidNotificationChannel(
    updatesChannelId,
    _updatesChannelName,
    description: 'New wallpapers, ringtones and offers',
    importance: Importance.defaultImportance,
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

  /// Resolve the device IANA zone → `tz.local`. Independent of plugin init, so it overlaps it.
  /// An unresolvable zone leaves `tz.local` as UTC -> reminders still fire, at the wrong wall clock.
  Future<void> _applyLocalTimezone() async {
    try {
      final info = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(info.identifier));
    } catch (_) {
      // Deliberately swallowed — a wrong hour beats no reminders.
    }
  }

  /// Routes a tap to the category it was about — the payload is the category slug.
  /// Anything unrecognised, or a null handler before the app is up, falls through to opening the app.
  void _onTap(NotificationResponse response) {
    final payload = response.payload;
    if (payload == null || payload.isEmpty) return;
    // The one payload that is not a category. Checked first — a slug can never collide with it.
    if (payload == trialReminderPayload) {
      onOpenTrialReminder?.call();
      return;
    }
    onOpenCategory?.call(payload);
  }

  /// Prompts for the Android 13+ runtime permission and returns whether posting is allowed.
  /// Call it when the user turns the feature ON — never at launch.
  Future<bool> requestPermissions() {
    // The OS dialog is modal but the toggle behind it is NOT -> a second tap threw from an
    // unawaited future (`permissionRequestInProgress`).
    // So single-flight — both taps share the one answer.
    return _permissionRequest ??= _requestPermissions().whenComplete(
      () => _permissionRequest = null,
    );
  }

  Future<bool>? _permissionRequest;

  Future<bool> _requestPermissions() async {
    final android = _android;
    if (android == null) return false;
    try {
      return await android.requestNotificationsPermission() ?? false;
    } on PlatformException catch (e) {
      // Defensive — a request the single-flight did not see; "not granted" is the honest answer.
      debugPrint('[NotificationService] permission request failed: $e');
      return false;
    }
  }

  /// The same MainActivity channel shape the ringtone Set uses for `WRITE_SETTINGS`:
  /// ask whether the grant screen is the only route left, then deep-link to it.
  static const _settingsChannel = MethodChannel(
    'com.hsrutility.arul/notification_settings',
  );

  /// True when the permission is refused AND Android will no longer show its dialog.
  /// Only meaningful right after a [requestPermissions] that came back false.
  Future<bool> notificationsBlocked() async {
    try {
      return await _settingsChannel.invokeMethod<bool>(
            'notificationsBlocked',
          ) ??
          false;
    } on PlatformException catch (e) {
      debugPrint('[NotificationService] blocked check failed: $e');
      return false;
    }
  }

  /// Opens Android's notification page for Arul — the toast names phone settings,
  /// so the tap has to land there rather than leaving the user to find it.
  Future<void> openNotificationSettings() async {
    try {
      await _settingsChannel.invokeMethod<void>('openNotificationSettings');
    } on PlatformException catch (e) {
      debugPrint('[NotificationService] open settings failed: $e');
    }
  }

  /// Whether the OS currently allows posting — it can be revoked in settings at any time.
  ///
  /// Null means UNKNOWN, never denied -> reading it as no would wipe a valid opt-in on an OEM build.
  Future<bool?> areNotificationsEnabled() =>
      _android?.areNotificationsEnabled() ?? Future.value(null);

  /// Cancels everything and re-schedules from [settings] — idempotent, safe on every change and launch.
  /// Accepting notifications enables the WHOLE set; there are no per-event opt-ins.
  /// Cancels everything and re-schedules from [settings].
  ///
  /// It cancels ALL, including the unfinished-trial reminder, which these settings do not own:
  /// ids are derived from list INDEXES, so a reordered or shortened list leaves orphans that only
  /// `cancelAll` reaches. `notificationBootstrap` re-arms the trial reminder afterwards from its
  /// persisted instant — that ordering is the contract, and it is why the instant is persisted.
  Future<void> applySettings(NotificationSettings settings) async {
    if (!_initialized) await initialize();
    await _plugin.cancelAll();
    if (!settings.masterEnabled) return;

    // Exact alarms need a special-access permission that shows on the Play listing -> inexact.
    // A few minutes' drift is immaterial for a weekly or seasonal reminder.
    const mode = AndroidScheduleMode.inexactAllowWhileIdle;

    await _scheduleWeekly(settings, mode);
    await _scheduleFestivals(settings, mode);
  }

  Future<void> cancelAll() async {
    // cancelAll on an UN-initialised plugin silently no-ops, and setup is deferred off startup.
    // So self-initialise here; initialize() is single-flight and never triggers a second setup.
    if (!_initialized) await initialize();
    await _plugin.cancelAll();
  }

  Future<void> _scheduleWeekly(
    NotificationSettings s,
    AndroidScheduleMode mode,
  ) async {
    for (var i = 0; i < weeklyDevotionalDays.length; i++) {
      final day = weeklyDevotionalDays[i];
      await _plugin.zonedSchedule(
        id: _weeklyIdBase + i,
        title: '${day.emoji} ${day.title}',
        body: day.body,
        scheduledDate: _nextWeekday(
          day.weekday,
          s.reminderHour,
          s.reminderMinute,
        ),
        notificationDetails: _details(
          _weeklyChannelId,
          _weeklyChannelName,
          body: day.body,
        ),
        androidScheduleMode: mode,
        matchDateTimeComponents: DateTimeComponents.dayOfWeekAndTime,
        payload: day.category,
      );
    }
  }

  Future<void> _scheduleFestivals(
    NotificationSettings s,
    AndroidScheduleMode mode,
  ) async {
    final now = tz.TZDateTime.now(tz.local);

    for (var i = 0; i < festivalEvents.length; i++) {
      final event = festivalEvents[i];

      // Walk forward until a date whose REMINDER instant is still in the future.
      // Taking the next date alone fires immediately for a festival 2 days out with a 3-day lead.
      tz.TZDateTime? when;
      // Plain DateTime, not TZDateTime — it only indexes the table, authored as wall-clock dates.
      DateTime cursor = now.subtract(const Duration(days: 1));
      while (true) {
        final date = event.nextOccurrenceAfter(cursor);
        // Table exhausted for this festival -> skip it rather than guess (see festivalEvents).
        if (date == null) break;
        final candidate = _reminderTime(date, s.reminderHour, s.reminderMinute);
        if (candidate.isAfter(now)) {
          when = candidate;
          break;
        }
        cursor = date;
      }
      if (when == null) continue;

      await _plugin.zonedSchedule(
        id: _festivalIdBase + i,
        title: '${event.emoji} ${event.title}',
        body: event.body,
        scheduledDate: when,
        notificationDetails: _details(
          _festivalChannelId,
          _festivalChannelName,
          body: event.body,
        ),
        androidScheduleMode: mode,
        payload: event.category,
        // One-shot — re-armed on the next launch (see the class doc).
      );
    }
  }

  /// The reminder instant — [kFestivalLeadDays] before [eventDate], at the user's chosen time.
  tz.TZDateTime _reminderTime(DateTime eventDate, int hour, int minute) {
    final d = eventDate.subtract(const Duration(days: kFestivalLeadDays));
    return tz.TZDateTime(tz.local, d.year, d.month, d.day, hour, minute);
  }

  NotificationDetails _details(
    String channelId,
    String channelName, {
    String? body,
  }) => NotificationDetails(
    android: AndroidNotificationDetails(
      channelId,
      channelName,
      icon: _icon,
      largeIcon: const DrawableResourceAndroidBitmap(_largeIcon),
      color: _accent,
      // Expanded layout -> the full body reads without pulling the shade open on a truncated line.
      styleInformation: body == null ? null : BigTextStyleInformation(body),
      importance: Importance.high,
      priority: Priority.high,
      // On O+ the CHANNEL's sound wins -> set here too, for explicit intent and pre-O devices.
      sound: _chime,
    ),
  );

  /// Next instant in the local zone for [hour]:[minute], strictly in the future.
  tz.TZDateTime _nextInstanceOfTime(int hour, int minute) {
    final now = tz.TZDateTime.now(tz.local);
    var scheduled = tz.TZDateTime(
      tz.local,
      now.year,
      now.month,
      now.day,
      hour,
      minute,
    );
    if (!scheduled.isAfter(now)) {
      scheduled = scheduled.add(const Duration(days: 1));
    }
    return scheduled;
  }

  /// Next occurrence of [weekday] (`DateTime.monday`…`sunday`) at [hour]:[minute].
  tz.TZDateTime _nextWeekday(int weekday, int hour, int minute) {
    var scheduled = _nextInstanceOfTime(hour, minute);
    while (scheduled.weekday != weekday) {
      scheduled = scheduled.add(const Duration(days: 1));
    }
    return scheduled;
  }

  // QA: reachable in debug AND in a sideloaded release APK, never in Play (`qaToolsEnabled`).
  // R8 stripping icons, a stale channel sound, an alarm that never armed happen ONLY in release.
  // So NOT gated on `kDebugMode` — a tool compiled out of release could never catch them.

  /// What is actually scheduled right now, newest-armed last.
  ///
  /// [previewAll] proves the copy and icons render, but never that anything was ARMED.
  /// A notification that looks perfect and never armed shows up only on the day it fails to arrive.
  /// So this reads the OS's own pending set — reality, not appearance.
  Future<List<PendingNotificationRequest>> pending() async {
    if (!_initialized) await initialize();
    return _plugin.pendingNotificationRequests();
  }

  /// A human-readable audit for the QA card — how many reminders are armed, and what they are.
  ///
  /// "12 armed" means nothing alone -> counts are COMPARED against the tables, not just reported.
  /// The number that matters is whether a festival was SKIPPED for want of a future date.
  /// That skip is silent by design and would otherwise surface as a reminder that never came.
  Future<NotificationAudit> audit() async {
    final armed = await pending();
    final weekly = armed.where((n) => n.id < _festivalIdBase).length;
    final festivals = armed.where((n) => n.id >= _festivalIdBase).length;
    return NotificationAudit(
      weeklyArmed: weekly,
      weeklyExpected: weeklyDevotionalDays.length,
      festivalsArmed: festivals,
      festivalsExpected: festivalEvents.length,
      titles: armed.map((n) => n.title ?? '(untitled)').toList(),
    );
  }

  /// Arms the ONE unfinished-trial reminder for [due]. False when nothing was scheduled.
  ///
  /// NEVER requests the permission: this fires from a payment failing, which is not an opt-in to
  /// notifications. A user who has not already said yes simply gets no reminder — the row on the
  /// feed is what covers them.
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
        // The EXISTING weekly channel, never a new one: a channel's sound is immutable once created
        // and a new id would show up as a second toggle in the system settings for one reminder.
        notificationDetails: _details(
          _weeklyChannelId,
          _weeklyChannelName,
          body: body,
        ),
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        payload: trialReminderPayload,
      );
      return true;
    } catch (e) {
      debugPrint('[TrialNudge] reminder not scheduled: $e');
      return false;
    }
  }

  /// Drops the unfinished-trial reminder — the trial was finished, or the marker aged out.
  Future<void> cancelTrialReminder() async {
    if (!_initialized) await initialize();
    await _plugin.cancel(id: _trialReminderId);
  }

  /// Fires a one-off notification [delay] from now -> the user confirms reminders actually arrive.
  /// Requests the permission first if needed.
  Future<void> scheduleTestNotification({
    Duration delay = const Duration(seconds: 5),
  }) async {
    if (!_initialized) await initialize();
    await requestPermissions();
    const body = 'If you can see this, reminders are working.';
    await _plugin.zonedSchedule(
      id: _testId,
      title: 'Arul test 🔔',
      body: body,
      scheduledDate: tz.TZDateTime.now(tz.local).add(delay),
      notificationDetails: _details(
        _weeklyChannelId,
        _weeklyChannelName,
        body: body,
      ),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
    );
  }

  /// Immediately posts the real weekly and festival notifications — production ids, channels, copy.
  /// So the whole set can be eyeballed without waiting for the calendar.
  /// A mock would prove nothing about the resources the shipped ones resolve BY NAME.
  Future<void> previewAll() async {
    if (!_initialized) await initialize();
    await requestPermissions();

    for (var i = 0; i < weeklyDevotionalDays.length; i++) {
      final day = weeklyDevotionalDays[i];
      await _plugin.show(
        id: _weeklyIdBase + i,
        title: '${day.emoji} ${day.title}',
        body: day.body,
        notificationDetails: _details(
          _weeklyChannelId,
          _weeklyChannelName,
          body: day.body,
        ),
        payload: day.category,
      );
    }

    for (var i = 0; i < festivalEvents.length; i++) {
      final event = festivalEvents[i];
      await _plugin.show(
        id: _festivalIdBase + i,
        title: '${event.emoji} ${event.title}',
        body: event.body,
        notificationDetails: _details(
          _festivalChannelId,
          _festivalChannelName,
          body: event.body,
        ),
        payload: event.category,
      );
    }
  }
}
