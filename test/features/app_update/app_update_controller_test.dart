import 'dart:async';

import 'package:arul/core/analytics/analytics_service.dart';
import 'package:arul/core/update/update_holds.dart';
import 'package:arul/data/models/app_config_model.dart';
import 'package:arul/features/app_update/data/app_update_client.dart';
import 'package:arul/features/app_update/domain/app_update_policy.dart';
import 'package:arul/features/app_update/providers/app_update_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeClient extends AppUpdateClient {
  _FakeClient() : super(const MethodChannel('test/app_update'));

  UpdateInfo info = const UpdateInfo(
    availability: UpdateAvailability.available,
    availableBuild: 85,
    immediateAllowed: true,
    flexibleAllowed: true,
  );
  String result = 'accepted';
  final starts = <bool>[];
  int checks = 0;
  int completes = 0;
  final states = StreamController<String>.broadcast();

  @override
  Stream<String> get installStates => states.stream;

  Object? checkError;

  @override
  Future<UpdateInfo> check() async {
    checks++;
    final error = checkError;
    if (error != null) throw error;
    return info;
  }

  @override
  Future<String> start({required bool immediate}) async {
    starts.add(immediate);
    return result;
  }

  @override
  Future<bool> completeUpdate() async {
    completes++;
    return true;
  }
}

class _Analytics implements AnalyticsService {
  final events = <String>[];
  @override
  void track(String event, {Map<String, Object?>? properties}) =>
      events.add('$event:${properties?['result'] ?? properties?['type']}');
  @override
  void identify(String userId, {Map<String, Object?>? userProperties}) {}
  @override
  void screen(String name, {Map<String, Object?>? properties}) {}
  @override
  void reset() {}
  @override
  void register(String key, Object value) {}
}

void main() {
  late _FakeClient client;
  late _Analytics analytics;
  late ValueNotifier<String> route;
  late DateTime clock;
  late AppUpdateController controller;
  late SharedPreferences prefs;
  var busy = false;

  Future<void> setUp0(
    WidgetTester tester, {
    Map<String, Object> stored = const {},
    AppConfigModel? config,
  }) async {
    SharedPreferences.setMockInitialValues(stored);
    prefs = await SharedPreferences.getInstance();
    busy = false;
    // As the bootstrap does on a Play install.
    UpdateHolds.launch.value = UpdateLaunch.undecided;
    addTearDown(() => UpdateHolds.launch.value = UpdateLaunch.clear);
    client = _FakeClient();
    analytics = _Analytics();
    route = ValueNotifier('/');
    clock = DateTime(2026, 9, 25, 12);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    controller = AppUpdateController(
      client: client,
      analytics: analytics,
      prefs: prefs,
      readConfig: () async => config,
      readInstalledBuild: () async => 84,
      routeChanges: route,
      location: () => route.value,
      hostBusy: () => busy,
      now: () => clock,
    )..start();
    addTearDown(controller.dispose);
  }

  Future<void> advance(WidgetTester tester, Duration by) async {
    clock = clock.add(by);
    await tester.pump(by);
  }

  Future<void> background(WidgetTester tester) async {
    for (final s in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(s);
    }
    await tester.pump();
  }

  Future<void> foreground(WidgetTester tester) async {
    for (final s in [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(s);
    }
    await tester.pump();
  }

  testWidgets('cold start waits for the splash to leave, then prompts once', (
    tester,
  ) async {
    await setUp0(tester);
    await advance(tester, const Duration(seconds: 5));
    expect(client.checks, 0);

    route.value = '/browse';
    await advance(tester, const Duration(milliseconds: 1400));
    expect(client.checks, 0);
    await advance(tester, const Duration(milliseconds: 200));
    expect(client.starts, [true]);
    expect(analytics.events, [
      'app_update_prompt:immediate',
      'app_update_result:accepted',
    ]);

    route.value = '/ringtones';
    await advance(tester, const Duration(seconds: 5));
    expect(client.starts, [true]);
  });

  testWidgets('a hold defers the prompt until 2 s after it drops', (
    tester,
  ) async {
    await setUp0(tester);
    final release = UpdateHolds.hold();
    route.value = '/browse';
    await advance(tester, const Duration(seconds: 10));
    expect(client.checks, 0);
    expect(UpdateHolds.launch.value, UpdateLaunch.undecided);

    release();
    await advance(tester, const Duration(milliseconds: 1900));
    expect(client.checks, 0);
    await advance(tester, const Duration(milliseconds: 200));
    expect(client.starts, [true]);
    expect(UpdateHolds.launch.value, UpdateLaunch.prompted);
  });

  testWidgets(
    'never over the sign-in wall: an attempt holds it, the wall defers it, the feed runs it',
    (tester) async {
      await setUp0(tester);
      route.value = '/sign-in';
      final release = UpdateHolds.hold();
      await advance(tester, const Duration(seconds: 10));
      release();
      await advance(tester, const Duration(seconds: 10));
      expect(client.checks, 0, reason: 'a cancelled sheet leaves the wall up');

      route.value = '/browse';
      await advance(tester, const Duration(milliseconds: 1900));
      expect(client.checks, 0);
      await advance(tester, const Duration(milliseconds: 200));
      expect(client.starts, [true]);
    },
  );

  testWidgets('an apply or set in flight defers it until it finishes', (
    tester,
  ) async {
    await setUp0(tester);
    busy = true;
    route.value = '/browse';
    await advance(tester, const Duration(seconds: 10));
    expect(client.checks, 0);

    busy = false;
    await advance(tester, const Duration(seconds: 3));
    expect(client.starts, [true]);
  });

  testWidgets(
    'no update -> no prompt, and the launch is clear for the review',
    (tester) async {
      await setUp0(tester);
      client.info = const UpdateInfo(availability: UpdateAvailability.none);
      route.value = '/browse';
      await advance(tester, const Duration(seconds: 2));
      expect(client.checks, 1);
      expect(client.starts, isEmpty);
      expect(analytics.events, isEmpty);
      expect(UpdateHolds.launch.value, UpdateLaunch.clear);
    },
  );

  testWidgets('mode flexible from the CMS -> the flexible flow', (
    tester,
  ) async {
    await setUp0(
      tester,
      config: const AppConfigModel(
        prices: {},
        policyUrls: {},
        featureFlags: {
          'app_update': {'mode': 'flexible'},
        },
      ),
    );
    route.value = '/browse';
    await advance(tester, const Duration(seconds: 2));
    expect(client.starts, [false]);
    expect(analytics.events.first, 'app_update_prompt:flexible');
  });

  testWidgets(
    'below min_supported_version -> immediate even when mode is off',
    (tester) async {
      await setUp0(
        tester,
        config: const AppConfigModel(
          prices: {},
          policyUrls: {},
          minSupportedVersion: '1.0.0+85',
          featureFlags: {
            'app_update': {'mode': 'off'},
          },
        ),
      );
      route.value = '/browse';
      await advance(tester, const Duration(seconds: 2));
      expect(client.starts, [true]);
    },
  );

  testWidgets('an interrupted immediate update is resumed', (tester) async {
    await setUp0(tester);
    client.info = const UpdateInfo(
      availability: UpdateAvailability.inProgress,
      installStatus: 'downloading',
    );
    route.value = '/browse';
    await advance(tester, const Duration(seconds: 2));
    expect(client.starts, [true]);
  });

  testWidgets('a flexible download in progress is never turned immediate', (
    tester,
  ) async {
    await setUp0(tester, stored: {'arul_update_flexible_started': true});
    client.info = const UpdateInfo(
      availability: UpdateAvailability.inProgress,
      installStatus: 'downloading',
    );
    route.value = '/browse';
    await advance(tester, const Duration(seconds: 2));
    expect(client.checks, 1);
    expect(client.starts, isEmpty);
  });

  testWidgets('a throwing check is swallowed and clears the launch', (
    tester,
  ) async {
    await setUp0(tester);
    client.checkError = PlatformException(code: 'boom');
    route.value = '/browse';
    await advance(tester, const Duration(seconds: 2));
    expect(client.checks, 1);
    expect(client.starts, isEmpty);
    expect(UpdateHolds.launch.value, UpdateLaunch.clear);
  });

  testWidgets('a decline blocks resume prompts for 30 min, not longer', (
    tester,
  ) async {
    await setUp0(tester);
    client.result = 'cancelled';
    route.value = '/browse';
    await advance(tester, const Duration(seconds: 2));
    expect(client.starts, [true]);

    await background(tester);
    await advance(tester, const Duration(minutes: 5));
    await foreground(tester);
    await advance(tester, const Duration(seconds: 3));
    expect(client.starts, [true], reason: 'inside the reprompt window');

    await background(tester);
    await advance(tester, const Duration(minutes: 30));
    await foreground(tester);
    await advance(tester, const Duration(seconds: 3));
    expect(client.starts, [true, true]);
  });

  testWidgets(
    'returning from Play\'s own screen or a short trip never re-prompts',
    (tester) async {
      await setUp0(tester);
      client.result = 'cancelled';
      route.value = '/browse';
      await advance(tester, const Duration(seconds: 2));
      final checks = client.checks;

      await background(tester);
      await advance(tester, const Duration(seconds: 2));
      await foreground(tester);
      await advance(tester, const Duration(seconds: 5));
      expect(client.checks, checks);
    },
  );

  testWidgets(
    'a finished flexible download installs on the next background, never under a hold',
    (tester) async {
      await setUp0(tester);
      client.info = const UpdateInfo(
        availability: UpdateAvailability.available,
        availableBuild: 85,
        flexibleAllowed: true,
      );
      route.value = '/browse';
      await advance(tester, const Duration(seconds: 2));
      expect(client.starts, [false]);

      client.states.add('downloaded');
      await tester.pump();
      final release = UpdateHolds.hold();
      await background(tester);
      expect(client.completes, 0);
      await foreground(tester);
      release();

      await background(tester);
      expect(client.completes, 1);
      await foreground(tester);
      await advance(tester, const Duration(seconds: 3));
    },
  );

  testWidgets('a check deferred by a system dialog runs once the app is back', (
    tester,
  ) async {
    await setUp0(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    route.value = '/browse';
    await advance(tester, const Duration(seconds: 5));
    expect(client.checks, 0);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await advance(tester, const Duration(seconds: 1));
    expect(client.checks, 0);
    await advance(tester, const Duration(seconds: 2));
    expect(client.starts, [true]);
  });

  testWidgets('an API error or no update is a silent no-op', (tester) async {
    await setUp0(tester);
    client.info = const UpdateInfo.unavailable('APP_NOT_OWNED');
    route.value = '/browse';
    await advance(tester, const Duration(seconds: 2));
    expect(client.checks, 1);
    expect(client.starts, isEmpty);
    expect(analytics.events, isEmpty);
  });
}
