import 'package:arul/features/app_update/domain/app_update_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime(2026, 9, 25, 12);
  const available = UpdateInfo(
    availability: UpdateAvailability.available,
    availableBuild: 85,
    immediateAllowed: true,
    flexibleAllowed: true,
  );

  UpdateAction run({
    UpdateInfo info = available,
    UpdateFlags flags = const UpdateFlags(),
    int installed = 84,
    int? minBuild,
    UpdateTrigger trigger = UpdateTrigger.coldStart,
    DateTime? declinedAt,
    bool flexibleStarted = false,
  }) => decide(
    info: info,
    flags: flags,
    installedBuild: installed,
    minBuild: minBuild,
    trigger: trigger,
    now: now,
    declinedAt: declinedAt,
    flexibleStarted: flexibleStarted,
  );

  group('parseMinBuild', () {
    test('reads a bare build or the +build suffix', () {
      expect(parseMinBuild('85'), 85);
      expect(parseMinBuild(' 85 '), 85);
      expect(parseMinBuild('1.0.0+85'), 85);
    });
    test('anything else is no floor', () {
      expect(parseMinBuild('1.0.0'), isNull);
      expect(parseMinBuild(''), isNull);
      expect(parseMinBuild(null), isNull);
      expect(parseMinBuild('abc'), isNull);
      expect(parseMinBuild('99999'), isNull);
    });
  });

  group('UpdateFlags.from', () {
    test('defaults to immediate with a 30 minute reprompt', () {
      final flags = UpdateFlags.from(null);
      expect(flags.mode, UpdateMode.immediate);
      expect(flags.reprompt, const Duration(minutes: 30));
    });
    test('reads mode and reprompt, ignores bad types', () {
      final flags = UpdateFlags.from({
        'app_update': {'mode': 'off', 'reprompt_minutes': 5},
      });
      expect(flags.mode, UpdateMode.off);
      expect(flags.reprompt, const Duration(minutes: 5));
      expect(
        UpdateFlags.from({'app_update': 'junk'}).mode,
        UpdateMode.immediate,
      );
    });
  });

  group('decide', () {
    test('nothing when Play offers nothing or the API failed', () {
      expect(
        run(info: const UpdateInfo(availability: UpdateAvailability.none)),
        UpdateAction.none,
      );
      expect(run(info: const UpdateInfo.unavailable('x')), UpdateAction.none);
    });

    test('an interrupted immediate update resumes', () {
      expect(
        run(
          info: const UpdateInfo(availability: UpdateAvailability.inProgress),
        ),
        UpdateAction.resumeImmediate,
      );
    });

    test('a flexible download in progress is left to finish', () {
      expect(
        run(
          info: const UpdateInfo(availability: UpdateAvailability.inProgress),
          flexibleStarted: true,
        ),
        UpdateAction.none,
      );
    });

    test('immediate by default, flexible when immediate is not allowed', () {
      expect(run(), UpdateAction.immediate);
      expect(
        run(
          info: const UpdateInfo(
            availability: UpdateAvailability.available,
            flexibleAllowed: true,
          ),
        ),
        UpdateAction.flexible,
      );
    });

    test('the CMS knob picks flexible or off', () {
      expect(
        run(flags: const UpdateFlags(mode: UpdateMode.flexible)),
        UpdateAction.flexible,
      );
      expect(
        run(flags: const UpdateFlags(mode: UpdateMode.off)),
        UpdateAction.none,
      );
    });

    test('a recent decline blocks resume prompts but never a cold start', () {
      final declined = now.subtract(const Duration(minutes: 10));
      expect(
        run(trigger: UpdateTrigger.resume, declinedAt: declined),
        UpdateAction.none,
      );
      expect(
        run(trigger: UpdateTrigger.holdRelease, declinedAt: declined),
        UpdateAction.none,
      );
      expect(run(declinedAt: declined), UpdateAction.immediate);
      expect(
        run(
          trigger: UpdateTrigger.resume,
          declinedAt: now.subtract(const Duration(minutes: 31)),
        ),
        UpdateAction.immediate,
      );
    });

    test('below the floor, the knob and the cooldown no longer apply', () {
      expect(
        run(
          minBuild: 85,
          flags: const UpdateFlags(mode: UpdateMode.off),
          trigger: UpdateTrigger.resume,
          declinedAt: now,
        ),
        UpdateAction.immediate,
      );
    });

    test('a split-per-abi code compares by its build', () {
      expect(
        run(
          installed: 2085,
          minBuild: 85,
          flags: const UpdateFlags(mode: UpdateMode.off),
        ),
        UpdateAction.none,
      );
    });
  });
}
