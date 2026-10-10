// The campaign channel is decided ONCE from the user's level on the channel campaigns used before:
// blocked stays blocked, quietened stays quiet, anything else pops up — with the bell. Local posts
// never move.

import 'package:arul/features/notifications/data/notification_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/timezone.dart' as tz;

class _FakeAndroid implements AndroidFlutterLocalNotificationsPlugin {
  _FakeAndroid(this.channels);

  /// What the phone already holds, as `getNotificationChannels` would report it.
  final List<AndroidNotificationChannel> channels;
  final created = <AndroidNotificationChannel>[];
  final deleted = <String>[];
  int reads = 0;

  @override
  Future<List<AndroidNotificationChannel>?> getNotificationChannels() async {
    reads++;
    return channels;
  }

  @override
  Future<void> createNotificationChannel(AndroidNotificationChannel c) async {
    created.add(c);
  }

  @override
  Future<void> deleteNotificationChannel({required String channelId}) async =>
      deleted.add(channelId);

  @override
  Future<bool?> areNotificationsEnabled() async => true;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    '${invocation.memberName} is not part of this test',
  );
}

class _FakePlugin implements FlutterLocalNotificationsPlugin {
  _FakePlugin(this.android);

  final _FakeAndroid android;
  final scheduled = <NotificationDetails>[];

  @override
  Future<bool?> initialize({
    required InitializationSettings settings,
    DidReceiveNotificationResponseCallback? onDidReceiveNotificationResponse,
    DidReceiveBackgroundNotificationResponseCallback?
    onDidReceiveBackgroundNotificationResponse,
  }) async => true;

  @override
  T? resolvePlatformSpecificImplementation<
    T extends FlutterLocalNotificationsPlatform
  >() => android as T;

  @override
  Future<List<PendingNotificationRequest>>
  pendingNotificationRequests() async => const [];

  @override
  Future<void> zonedSchedule({
    required int id,
    required tz.TZDateTime scheduledDate,
    required NotificationDetails notificationDetails,
    required AndroidScheduleMode androidScheduleMode,
    String? title,
    String? body,
    String? payload,
    DateTimeComponents? matchDateTimeComponents,
  }) async => scheduled.add(notificationDetails);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    '${invocation.memberName} is not part of this test',
  );
}

AndroidNotificationChannel _legacyCampaigns(Importance importance) =>
    AndroidNotificationChannel(
      NotificationService.legacyCampaignChannelId,
      'New wallpapers and offers',
      importance: importance,
    );

AndroidNotificationChannel _updates(Importance importance) =>
    AndroidNotificationChannel(
      NotificationService.updatesChannelId,
      'Updates from Arul',
      importance: importance,
    );

Future<(NotificationService, _FakePlugin, SharedPreferences)> _boot(
  List<AndroidNotificationChannel> onPhone, {
  Map<String, Object> prefs = const {},
}) async {
  SharedPreferences.setMockInitialValues(prefs);
  final store = await SharedPreferences.getInstance();
  final plugin = _FakePlugin(_FakeAndroid(onPhone));
  final service = NotificationService(prefs: store, plugin: plugin);
  await service.initialize();
  return (service, plugin, store);
}

List<AndroidNotificationChannel> _campaignCreates(_FakePlugin p) => p
    .android
    .created
    .where((c) => c.id == NotificationService.campaignChannelId)
    .toList();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'the level rule: blocked -> none, quietened -> the same, anything else -> high',
    () {
      expect(
        NotificationService.campaignImportanceFor(Importance.none),
        isNull,
      );
      expect(
        NotificationService.campaignImportanceFor(Importance.min),
        Importance.min,
      );
      expect(
        NotificationService.campaignImportanceFor(Importance.low),
        Importance.low,
      );
      for (final level in [
        Importance.defaultImportance,
        Importance.high,
        Importance.max,
        Importance.unspecified,
        null,
      ]) {
        expect(
          NotificationService.campaignImportanceFor(level),
          Importance.high,
        );
      }
    },
  );

  test(
    'blocked updates channel: the campaign channel is never created, on any launch',
    () async {
      final (_, plugin, prefs) = await _boot([_updates(Importance.none)]);
      expect(_campaignCreates(plugin), isEmpty);
      expect(
        prefs.getInt(NotificationService.campaignChannelPrefKey),
        Importance.none.value,
      );

      // Next launch: the stored decision holds even if the old channel was unblocked since.
      final again = _FakePlugin(
        _FakeAndroid([_updates(Importance.defaultImportance)]),
      );
      final service = NotificationService(prefs: prefs, plugin: again);
      await service.initialize();
      await service.setCampaignChannelName('Renamed');
      expect(_campaignCreates(again), isEmpty);
      expect(again.android.reads, 0);
    },
  );

  test(
    'a quietened updates channel makes a campaign channel at that same level',
    () async {
      for (final level in [Importance.low, Importance.min]) {
        final (_, plugin, prefs) = await _boot([_updates(level)]);
        expect(_campaignCreates(plugin).single.importance, level);
        expect(
          prefs.getInt(NotificationService.campaignChannelPrefKey),
          level.value,
        );
      }
    },
  );

  test(
    'otherwise the campaign channel pops up, ringing the bell',
    () async {
      final (_, plugin, prefs) = await _boot([
        _updates(Importance.defaultImportance),
      ]);
      final created = _campaignCreates(plugin).single;
      expect(created.importance, Importance.high);
      expect(created.playSound, isTrue);
      expect(created.sound, isA<RawResourceAndroidNotificationSound>());
      expect(created.sound?.sound, 'arul_bell');
      expect(
        prefs.getInt(NotificationService.campaignChannelPrefKey),
        Importance.high.value,
      );
    },
  );

  test(
    'decided once: a later launch re-creates at the stored level without reading again',
    () async {
      final (_, plugin, _) = await _boot(
        [_updates(Importance.none)],
        prefs: {
          NotificationService.campaignChannelPrefKey: Importance.low.value,
        },
      );
      expect(plugin.android.reads, 0);
      expect(_campaignCreates(plugin).single.importance, Importance.low);
    },
  );

  test(
    'a rename re-creates the campaign channel at its own level, in the new name',
    () async {
      final (service, plugin, _) = await _boot([_updates(Importance.low)]);
      await service.setCampaignChannelName('புதிய வால்பேப்பர்கள், சலுகைகள்');
      final last = _campaignCreates(plugin).last;
      expect(last.name, 'புதிய வால்பேப்பர்கள், சலுகைகள்');
      expect(last.importance, Importance.low);
    },
  );

  test('local posts stay on the updates channel', () async {
    final (service, plugin, _) = await _boot([
      _updates(Importance.defaultImportance),
    ]);
    await service.scheduleTrialReminder(
      due: DateTime.now().add(const Duration(hours: 6)),
      title: 't',
      body: 'b',
    );
    await service.scheduleComeBack(
      due: DateTime.now().add(const Duration(hours: 1)),
      title: 't',
      body: 'b',
    );
    expect(plugin.scheduled, hasLength(2));
    for (final d in plugin.scheduled) {
      expect(d.android?.channelId, NotificationService.updatesChannelId);
    }
  });

  group('the bell channel takes over from the silent one', () {
    test('the level rule: blocked stays out, any lowered level carries over, else high', () {
      expect(NotificationService.bellImportanceFor(Importance.none), isNull);
      for (final level in [
        Importance.min,
        Importance.low,
        Importance.defaultImportance,
      ]) {
        expect(NotificationService.bellImportanceFor(level), level);
      }
      for (final level in [Importance.high, Importance.max, null]) {
        expect(NotificationService.bellImportanceFor(level), Importance.high);
      }
    });

    test('a heads-up v1 becomes a heads-up bell channel, and v1 goes', () async {
      final (_, plugin, prefs) = await _boot([
        _updates(Importance.defaultImportance),
        _legacyCampaigns(Importance.high),
      ]);
      final created = _campaignCreates(plugin).single;
      expect(created.importance, Importance.high);
      expect(created.sound?.sound, 'arul_bell');
      expect(
        plugin.android.deleted,
        contains(NotificationService.legacyCampaignChannelId),
      );
      expect(
        prefs.getInt(NotificationService.campaignChannelPrefKey),
        Importance.high.value,
      );
    });

    test('a v1 the person lowered keeps that level', () async {
      final (_, plugin, _) = await _boot([
        _updates(Importance.defaultImportance),
        _legacyCampaigns(Importance.low),
      ]);
      expect(_campaignCreates(plugin).single.importance, Importance.low);
    });

    test('a blocked v1 is never replaced and never deleted', () async {
      final (_, plugin, prefs) = await _boot([
        _updates(Importance.defaultImportance),
        _legacyCampaigns(Importance.none),
      ]);
      expect(_campaignCreates(plugin), isEmpty);
      expect(plugin.android.deleted, isNot(contains(NotificationService.legacyCampaignChannelId)));
      expect(
        prefs.getInt(NotificationService.campaignChannelPrefKey),
        Importance.none.value,
      );
    });

    test('v1 skipped for a blocked updates channel stays skipped, even if unblocked since', () async {
      final (_, plugin, _) = await _boot(
        [_updates(Importance.defaultImportance)],
        prefs: {
          NotificationService.legacyCampaignPrefKey: Importance.none.value,
        },
      );
      expect(_campaignCreates(plugin), isEmpty);
    });
  });
}
