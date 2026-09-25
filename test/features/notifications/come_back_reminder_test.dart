// B3's contract: ONE post per install, armed at the first Google surface on Android 12 and below in
// the reminder arm, and disarmed by anything that shows the person came back.

import 'dart:async';

import 'package:arul/features/notifications/data/notification_service.dart';
import 'package:arul/features/notifications/providers/come_back_reminder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeNotifications implements NotificationService {
  final armed = <DateTime>[];
  String? picture;
  int cancels = 0;
  bool enabled = true;
  Completer<void>? hold;

  @override
  Future<bool> scheduleComeBack({
    required DateTime due,
    required String title,
    required String body,
    String? picturePath,
  }) async {
    await hold?.future;
    if (!enabled) return false;
    armed.add(due);
    picture = picturePath;
    return true;
  }

  @override
  Future<void> cancelComeBack() async => cancels++;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    '${invocation.memberName} is not part of this test',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final t0 = DateTime(2026, 9, 26, 10);
  late SharedPreferences prefs;
  late _FakeNotifications notifications;

  Future<ComeBackReminder> reminder({
    bool active = true,
    int? sdk = 31,
    Map<String, Object> stored = const {},
  }) async {
    SharedPreferences.setMockInitialValues(stored);
    prefs = await SharedPreferences.getInstance();
    notifications = _FakeNotifications();
    return ComeBackReminder(
      prefs: prefs,
      notifications: notifications,
      active: active,
      sdkInt: () async => sdk,
      copy: () => (title: 'Your wallpaper is ready', body: 'One tap'),
      picture: () async => '/files/poster.webp',
      now: () => t0,
    );
  }

  test(
    'arms one post an hour after the first surface, with the poster',
    () async {
      final r = await reminder();
      await r.onSurfaceShown();
      expect(notifications.armed, [t0.add(const Duration(minutes: 60))]);
      expect(notifications.picture, '/files/poster.webp');
      expect(prefs.getInt(ComeBackReminder.dueKey), isNotNull);

      await r.onSurfaceShown();
      expect(notifications.armed, hasLength(1), reason: 'once per install');
    },
  );

  test('never on Android 13+, an unknown SDK or the control arm', () async {
    for (final (active, sdk) in [
      (true, 33),
      (true, 36),
      (true, null),
      (false, 26),
    ]) {
      final r = await reminder(active: active, sdk: sdk);
      await r.onSurfaceShown();
      expect(notifications.armed, isEmpty, reason: '$active/$sdk');
    }
  });

  test('once per install even when the first schedule was refused', () async {
    final r = await reminder();
    notifications.enabled = false;
    await r.onSurfaceShown();
    notifications.enabled = true;
    await r.onSurfaceShown();
    expect(notifications.armed, isEmpty);

    final next = await reminder(stored: {ComeBackReminder.usedKey: true});
    await next.onSurfaceShown();
    expect(notifications.armed, isEmpty);
  });

  test('an outcome, a resume or a cold start disarms it', () async {
    final r = await reminder();
    await r.onSurfaceShown();
    await r.disarm();
    expect(notifications.cancels, 1);
    expect(prefs.getInt(ComeBackReminder.dueKey), isNull);

    await r.disarm();
    expect(notifications.cancels, 1, reason: 'nothing left to cancel');

    final cold = await reminder(
      stored: {ComeBackReminder.dueKey: 1, ComeBackReminder.usedKey: true},
    );
    await cold.coldStart();
    expect(notifications.cancels, 1);
    expect(prefs.getInt(ComeBackReminder.dueKey), isNull);
  });

  test(
    'a person back before the plugin answered leaves nothing armed',
    () async {
      final r = await reminder();
      notifications.hold = Completer<void>();
      final arming = r.onSurfaceShown();
      await Future<void>.delayed(Duration.zero);
      await r.disarm();
      notifications.hold!.complete();
      await arming;
      expect(notifications.cancels, 1);
      expect(prefs.getInt(ComeBackReminder.dueKey), isNull);
    },
  );
}
