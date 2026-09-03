// The PostHog gate rests on ONE fact about the process: did Play install this build?
// The probe answers it once and every consumer reads the cached verdict -> these pin the verdict, its
// failure direction and its caching, because each of those was chosen for a reason:
//   * a channel ERROR answers Play -> a real user's events are never dropped because a channel hiccuped;
//   * a MISSING channel answers not-Play -> `flutter test` and host builds report nothing;
//   * the answer is asked once -> the analytics assembly and the QA-tools gate can never disagree.
// The wiring itself (`PlayInstall.isPlay` in the sink assembly) cannot be exercised here: PostHog is
// only assembled when POSTHOG_KEY is defined, which `flutter test` never does.

import 'package:arul/core/config/build_info.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _channel = MethodChannel('com.hsrutility.arul/build_info');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  var probes = 0;

  void mockInstaller(Future<Object?> Function() answer) {
    messenger.setMockMethodCallHandler(_channel, (call) async {
      if (call.method != 'isPlayInstall') return null;
      probes++;
      return answer();
    });
  }

  setUp(() {
    probes = 0;
    PlayInstall.resetForTesting();
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(_channel, null);
    PlayInstall.resetForTesting();
  });

  group('PlayInstall.resolved', () {
    test('a Play installer answers true and is cached', () async {
      mockInstaller(() async => true);
      expect(await PlayInstall.resolved, isTrue);
      expect(PlayInstall.isPlay, isTrue);
    });

    test('a sideloaded build answers false — the sink stays off', () async {
      mockInstaller(() async => false);
      expect(await PlayInstall.resolved, isFalse);
      expect(PlayInstall.isPlay, isFalse);
    });

    test(
      'a platform error fails toward PLAY — never drop a real user',
      () async {
        mockInstaller(() async => throw PlatformException(code: 'boom'));
        expect(await PlayInstall.resolved, isTrue);
        expect(PlayInstall.isPlay, isTrue);
      },
    );

    test('no channel at all is not a store build', () async {
      // No handler registered -> the binding throws MissingPluginException, exactly like `flutter test`.
      expect(await PlayInstall.resolved, isFalse);
      expect(PlayInstall.isPlay, isFalse);
    });

    test('the probe runs ONCE per process, whoever asks', () async {
      mockInstaller(() async => false);
      await PlayInstall.resolved;
      await PlayInstall.resolved;
      await PlayInstall.resolved;
      expect(probes, 1);
    });

    test('before the probe lands the default is Play', () {
      // main() awaits `resolved` before the SDK starts, so no shipped event is ever gated on this
      // default; the default itself still has to point the safe way for anything that reads early.
      expect(PlayInstall.isPlay, isTrue);
    });
  });
}
