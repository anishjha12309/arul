// The WRITE_SETTINGS grant round trip. Android grants "Modify system settings"
// on a Settings screen, not in a dialog, so the Set tap that discovers the
// missing permission leaves the app. The request must finish BY ITSELF when the
// user comes back holding the grant — the first cut parked nothing, and the
// visible result was "I granted it and nothing happened": no ringtone and no
// "ringtone set" popup until a second tap (owner's device, 2026-08-22).
//
// Driven through the real WidgetsBinding lifecycle, because that is the only
// signal the notifier has that the user is back.

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arul/core/analytics/analytics_provider.dart';
import 'package:arul/core/analytics/analytics_service.dart';
import 'package:arul/data/models/ringtone.dart';
import 'package:arul/features/ringtones/data/ringtone_set_service.dart';
import 'package:arul/features/ringtones/providers/ringtone_set_provider.dart';

class _FakeSetService implements RingtoneSetService {
  bool canWrite = false;
  int settingsOpened = 0;
  final sets = <String>[];

  @override
  Future<bool> canWriteSettings() async => canWrite;

  @override
  Future<void> openWriteSettings() async => settingsOpened++;

  @override
  Future<String> fetchSignedUrl(String id) async => 'https://cdn/$id';

  @override
  Future<File> downloadFile(
    String url,
    String filename,
    void Function(double) onProgress,
  ) async {
    onProgress(1);
    return File(filename);
  }

  @override
  Future<void> setRingtone(
    File file,
    RingtoneTarget target, {
    required String title,
    required String mime,
  }) async => sets.add(title);
}

class _NoopAnalytics implements AnalyticsService {
  @override
  void track(String event, {Map<String, Object?>? properties}) {}
  @override
  void identify(String userId, {Map<String, Object?>? userProperties}) {}
  @override
  void screen(String name, {Map<String, Object?>? properties}) {}
  @override
  void reset() {}
}

const _tone = Ringtone(
  id: 'r1',
  title: 'Kanda Sashti Kavasam',
  category: 'murugan',
  audioKey: 'r1.mp3',
);

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeSetService service;
  late ProviderContainer container;

  setUp(() {
    service = _FakeSetService();
    container = ProviderContainer(
      overrides: [
        ringtoneSetServiceProvider.overrideWithValue(service),
        analyticsServiceProvider.overrideWithValue(_NoopAnalytics()),
      ],
    );
    addTearDown(container.dispose);
  });

  /// The app leaving for the Settings screen and coming back.
  Future<void> roundTrip() async {
    // The engine walks every intermediate state; a listener rejects a jump
    // straight from paused to resumed, so the test walks them too.
    for (final state in const [
      AppLifecycleState.resumed,
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      binding.handleAppLifecycleStateChanged(state);
    }
    // The resumed set is a chain of awaits on the fake service.
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  test('a missing grant opens Settings once and sets nothing yet', () async {
    await container
        .read(ringtoneSetProvider.notifier)
        .setRingtone(_tone, RingtoneTarget.ringtone);

    expect(service.settingsOpened, 1);
    expect(service.sets, isEmpty);
    expect(container.read(ringtoneSetProvider), isA<RingtoneSetIdle>());
  });

  test('coming back WITH the grant finishes the parked set by itself — '
      'the popup fires on the first apply, not the second', () async {
    final notifier = container.read(ringtoneSetProvider.notifier);
    await notifier.setRingtone(_tone, RingtoneTarget.ringtone);

    service.canWrite = true;
    await roundTrip();

    expect(service.sets, ['Kanda Sashti Kavasam']);
    expect(container.read(ringtoneSetProvider), isA<RingtoneSetSuccess>());
    expect(service.settingsOpened, 1, reason: 'never re-opens Settings');
  });

  test(
    'the parked set runs ONCE — a later resume does not replay it',
    () async {
      final notifier = container.read(ringtoneSetProvider.notifier);
      await notifier.setRingtone(_tone, RingtoneTarget.ringtone);
      service.canWrite = true;
      await roundTrip();
      notifier.reset();

      await roundTrip();

      expect(service.sets, hasLength(1));
      expect(container.read(ringtoneSetProvider), isA<RingtoneSetIdle>());
    },
  );

  test('coming back WITHOUT the grant drops the request: no set, and no '
      'Settings re-open loop', () async {
    await container
        .read(ringtoneSetProvider.notifier)
        .setRingtone(_tone, RingtoneTarget.ringtone);

    await roundTrip();

    expect(service.sets, isEmpty);
    expect(service.settingsOpened, 1);
    expect(container.read(ringtoneSetProvider), isA<RingtoneSetIdle>());

    // And it stays dropped: a grant made later is picked up by the NEXT tap,
    // not by a stale request.
    service.canWrite = true;
    await roundTrip();
    expect(service.sets, isEmpty);
  });
}
