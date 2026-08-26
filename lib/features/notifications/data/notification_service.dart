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
/// [festivalsArmed] short of [festivalsExpected] is the interesting case and is
/// NOT a defect: a festival whose dates have run out is skipped on purpose. It
/// is surfaced because that skip is otherwise completely silent.
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

/// Owns the [FlutterLocalNotificationsPlugin] and turns [NotificationSettings]
/// into scheduled local notifications.
///
/// Fully on-device: **no FCM, no network, no server**. Nothing here talks to the
/// Worker, and no notification content ever leaves the phone — which is also why
/// there is no push channel to promise users elsewhere in the app.
///
/// Scheduling model, and why the two halves differ:
///  * **Weekly** ([weeklyDevotionalDays]) — a native recurring alarm via
///    `DateTimeComponents.dayOfWeekAndTime`. The OS repeats it forever; we arm
///    it once.
///  * **Festivals** ([festivalEvents]) — one-shot alarms at the next dated
///    occurrence. A Hindu lunisolar festival has no expressible recurrence rule,
///    so these are re-armed on every app launch by `notificationBootstrapProvider`
///    and simply skipped once the table runs out (see [FestivalEvent]).
class NotificationService {
  NotificationService([FlutterLocalNotificationsPlugin? plugin])
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;

  // ─── Ids ────────────────────────────────────────────────────────────────────
  //
  // Stable and non-overlapping. Derived from the event's INDEX rather than a
  // hash so they stay small and legible in `adb shell dumpsys notification`;
  // reordering either list therefore reshuffles ids, which is harmless (the next
  // applySettings cancels everything first) but the keys are the identity, not
  // these numbers.
  static const _weeklyIdBase = 1000;
  static const _festivalIdBase = 2000;
  static const _testId = 9999;

  // ─── Resources ──────────────────────────────────────────────────────────────

  /// Monochrome status-bar silhouette. Android tints it, so it can NOT be the
  /// coloured launcher icon — that renders as a white square.
  static const _icon = 'ic_notification';

  /// The coloured brand mark, shown beside the text.
  static const _largeIcon = 'ic_notification_large';

  /// Whether `res/raw/arul_bell.mp3` is present in the build.
  ///
  /// FALSE, deliberately: the chime has not been supplied yet, and referencing a
  /// raw resource that does not exist makes the plugin fail channel creation
  /// outright — which would take every reminder down, not just its sound. Until
  /// the file lands the reminders use the device's default notification tone.
  ///
  /// Switching it on is a two-line change (this flag + the channel-id bump that
  /// a new sound requires) — the procedure is in `docs/notifications.md`.
  static const bool _kChimeBundled = false;

  static const _sound = RawResourceAndroidNotificationSound('arul_bell');
  static AndroidNotificationSound? get _chime => _kChimeBundled ? _sound : null;

  /// Arul gold (`ArulTokens.gold`). Tints the app name and the accent line so
  /// the notification reads as ours rather than as generic system chrome.
  ///
  /// Hard-coded rather than imported from the theme on purpose: this class runs
  /// far from the widget tree (a boot receiver can drive it with no Flutter UI
  /// alive at all), so it must not depend on anything that needs a BuildContext.
  static const _accent = Color(0xFFD4A017);

  // ─── Channels ───────────────────────────────────────────────────────────────
  //
  // The `_v1` suffix is load-bearing for the future: a channel's SOUND is
  // immutable once the channel exists on a device, so bundling the chime later
  // requires a new id (and the old one added to _legacyChannelIds). See
  // docs/notifications.md.
  static const _weeklyChannelId = 'arul_devotional_weekly_v1';
  static const _weeklyChannelName = 'Weekly devotional reminders';
  static const _festivalChannelId = 'arul_festivals_v1';
  static const _festivalChannelName = 'Festival reminders';

  /// Superseded channels, deleted on init so they don't linger as stale
  /// duplicates in the system notification settings. Empty today — the first
  /// entries will be the `_v1` ids above, when the chime forces a `_v2`.
  static const _legacyChannelIds = <String>[];

  bool _initialized = false;

  /// In-flight (or completed) initialisation, so concurrent callers share ONE
  /// setup instead of racing two. This matters because plugin init is deferred
  /// off startup (see main.dart): the deferred warm-up and a bootstrap-driven
  /// `applySettings`/`cancelAll` can both reach [initialize] at once.
  Future<void>? _initFuture;

  AndroidFlutterLocalNotificationsPlugin? get _android => _plugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >();

  /// Set by the app once the router exists, so a notification tap can open the
  /// feed on the right category. Null until then — a tap that arrives before the
  /// app is ready simply opens the app, which is the correct fallback.
  void Function(String category)? onOpenCategory;

  /// One-time setup: timezone database, plugin init, channel creation. Does NOT
  /// prompt for any permission — that happens on opt-in ([requestPermissions]).
  /// Single-flight via [_initFuture] so overlapping callers don't double-init.
  Future<void> initialize() => _initFuture ??= _doInitialize();

  Future<void> _doInitialize() async {
    // The IANA tz database parse is synchronous UI-isolate work. It stays here,
    // deferred off main()'s critical path, so it never gates the first frame.
    // Resolving the device zone and initialising the plugin are independent, so
    // overlap them rather than awaiting in series.
    tzdata.initializeTimeZones();
    final tzFuture = _applyLocalTimezone();

    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings(_icon),
      ),
      onDidReceiveNotificationResponse: _onTap,
    );

    final android = _android;
    // The channel creates and the legacy deletes are independent Binder
    // round-trips — fire them together with the tz resolution instead of
    // awaiting each in turn.
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
        for (final id in _legacyChannelIds)
          android.deleteNotificationChannel(channelId: id),
      ],
    ]);

    _initialized = true;
  }

  /// Resolve the device IANA zone → `tz.local`. Independent of plugin init, so
  /// it overlaps it. An unresolvable zone (rare) leaves `tz.local` as UTC:
  /// reminders still fire, their wall-clock time is just off for that user.
  Future<void> _applyLocalTimezone() async {
    try {
      final info = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(info.identifier));
    } catch (_) {
      // Deliberately swallowed — a wrong hour beats no reminders.
    }
  }

  /// Routes a notification tap to the category it was about. The payload is the
  /// category slug; anything unrecognised (or a null handler, because the app
  /// isn't up yet) falls through to just opening the app.
  void _onTap(NotificationResponse response) {
    final payload = response.payload;
    if (payload == null || payload.isEmpty) return;
    onOpenCategory?.call(payload);
  }

  /// Prompts for the runtime notification permission (Android 13+). Returns
  /// whether notifications are allowed. Call this when the user turns the
  /// feature on — never at launch.
  Future<bool> requestPermissions() {
    // Single-flight: the OS dialog is modal, but the toggle behind it is not.
    // A second tap while the sheet is up made the plugin throw
    // `permissionRequestInProgress` out of an unawaited future (22 users in
    // 30 days, Crashlytics 2026-08-26). Both taps now share the one answer.
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
      // Defensive: a request the single-flight above did not see (a plugin
      // re-entry from another surface). Not granted is the honest answer.
      debugPrint('[NotificationService] permission request failed: $e');
      return false;
    }
  }

  /// Whether the OS currently allows this app to post notifications — the
  /// permission can be revoked in system settings at any time, silently
  /// invalidating the in-app opt-in.
  ///
  /// Null means UNKNOWN and callers must NOT read it as denied: on an OEM build
  /// that can't answer, a null-means-no reading would wipe a valid opt-in.
  Future<bool?> areNotificationsEnabled() =>
      _android?.areNotificationsEnabled() ?? Future.value(null);

  /// Cancels everything and re-schedules from [settings]. Idempotent — safe on
  /// every settings change and on every launch. Accepting notifications enables
  /// the WHOLE set; there are no per-event opt-ins.
  Future<void> applySettings(NotificationSettings settings) async {
    if (!_initialized) await initialize();
    await _plugin.cancelAll();
    if (!settings.masterEnabled) return;

    // Inexact scheduling, so no exact-alarm permission is needed (that one is
    // special-access and shows on the Play listing). A few minutes' drift is
    // immaterial for a weekly or seasonal reminder.
    const mode = AndroidScheduleMode.inexactAllowWhileIdle;

    await _scheduleWeekly(settings, mode);
    await _scheduleFestivals(settings, mode);
  }

  Future<void> cancelAll() async {
    // Self-initialise: plugin setup is deferred off startup, so the bootstrap's
    // disabled-path cancelAll can run before the post-frame warm-up — and
    // cancelAll on an un-initialised plugin silently no-ops. initialize() is
    // single-flight, so this never triggers a second setup.
    if (!_initialized) await initialize();
    await _plugin.cancelAll();
  }

  // ─── Scheduling ─────────────────────────────────────────────────────────────

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

      // Walk forward through this festival's dates until one whose REMINDER
      // instant is still in the future. Simply taking the next date would skip
      // a festival that is 2 days away when the lead is 3 — its reminder
      // instant has already passed, so the alarm would fire immediately.
      tz.TZDateTime? when;
      // Plain DateTime, not TZDateTime: this only ever indexes into the
      // festival table, which is authored as wall-clock calendar dates.
      DateTime cursor = now.subtract(const Duration(days: 1));
      while (true) {
        final date = event.nextOccurrenceAfter(cursor);
        // Table exhausted for this festival. Skip it rather than guess: see the
        // banner on festivalEvents.
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

  /// The reminder instant: [kFestivalLeadDays] before [eventDate], at the user's
  /// chosen time.
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
      // Expanded layout, so the full body is readable without the user having
      // to pull the shade open on a truncated line.
      styleInformation: body == null ? null : BigTextStyleInformation(body),
      importance: Importance.high,
      priority: Priority.high,
      // On O+ the CHANNEL's sound wins; set here too so the intent is explicit
      // and pre-O devices still play it.
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

  // ─── QA ─────────────────────────────────────────────────────────────────────
  //
  // Reachable in debug AND in a sideloaded release APK, never in the Play build
  // — see `qaToolsEnabled`. None of this is gated on `kDebugMode`, deliberately:
  // the failures these tools exist to catch (R8 stripping the icons, a channel
  // that kept an old sound, an alarm that never armed) happen ONLY in a release
  // build, so tools that compile out of release could never have caught them.

  /// What is actually scheduled right now, newest-armed last.
  ///
  /// The one QA affordance that inspects reality rather than appearance:
  /// [previewAll] proves the copy and icons render, but a notification that
  /// looks perfect and was never armed is indistinguishable from a working one
  /// until the day it fails to arrive. This reads the OS's own pending set.
  Future<List<PendingNotificationRequest>> pending() async {
    if (!_initialized) await initialize();
    return _plugin.pendingNotificationRequests();
  }

  /// A human-readable audit of the schedule for the QA card: how many reminders
  /// are armed, and what they are.
  ///
  /// Counts are compared against the tables rather than just reported, because
  /// "12 armed" means nothing on its own — the number that matters is whether
  /// any festival was SKIPPED for want of a future date (see [FestivalEvent]),
  /// which is silent by design and would otherwise only surface as a reminder
  /// that never came.
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

  /// Fires a one-off notification [delay] from now so the user can confirm
  /// notifications actually arrive on their device. Requests the permission
  /// first if needed.
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

  /// Immediately posts the real weekly + every festival notification —
  /// production ids, channels, titles, copy, icons, accent and sound — so the
  /// whole set can be eyeballed without waiting for the calendar.
  ///
  /// Deliberately the REAL notifications and not stand-ins: rendering a mock
  /// would prove nothing about the resources the shipped ones resolve by name.
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
