// Both tap paths end in ONE open and ONE report, and nothing a payload carries can throw. The cold
// path is held by the real PushTapRouter until the splash decides auth -> the handler wired to it the
// way app.dart wires it, with stand-in screens.

import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:arul/core/analytics/analytics_service.dart';
import 'package:arul/core/api/api_client.dart';
import 'package:arul/core/crash/crash_reporter.dart';
import 'package:arul/core/deeplink/deep_link_target.dart';
import 'package:arul/features/push/data/push_open_handler.dart';
import 'package:arul/features/push/data/push_tap_router.dart';

const _campaign = '11111111-2222-4333-8444-555555555555';
const _wallpaper = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';

RemoteMessage _message(Map<String, String> data) => RemoteMessage(data: data);

void main() {
  setUp(ArulDeepLink.reset);
  tearDown(ArulDeepLink.reset);

  late _RecordingApi api;
  late _RecordingAnalytics analytics;
  late _RecordingCrash crash;
  late List<DeepLinkTarget> opened;
  late StreamController<RemoteMessage> openedStream;
  late StreamController<RemoteMessage> foregroundStream;

  setUp(() {
    api = _RecordingApi();
    analytics = _RecordingAnalytics();
    crash = _RecordingCrash();
    opened = [];
    openedStream = StreamController<RemoteMessage>.broadcast();
    foregroundStream = StreamController<RemoteMessage>.broadcast();
  });

  tearDown(() async {
    await openedStream.close();
    await foregroundStream.close();
  });

  PushOpenHandler make({
    RemoteMessage? initial,
    void Function(DeepLinkTarget)? onOpen,
  }) {
    final handler = PushOpenHandler(
      apiClient: api,
      analytics: analytics,
      crash: crash,
      onOpen: onOpen ?? opened.add,
      openedStream: openedStream.stream,
      foregroundStream: foregroundStream.stream,
      getInitialMessage: () async => initial,
    );
    addTearDown(handler.dispose);
    return handler;
  }

  test('a tap that launched a dead app opens once and reports once', () async {
    await make(
      initial: _message({
        'campaign_id': _campaign,
        'dest': 'wallpaper',
        'id': _wallpaper,
      }),
    ).start();

    expect(opened, [
      const WallpaperLinkTarget(_wallpaper, source: DeepLinkSource.push),
    ]);
    expect(api.posts, ['/me/push-opened $_campaign']);
    expect(analytics.events, ['push_opened']);
    expect(crash.errors, isEmpty);
  });

  test('a tap on a backgrounded app opens once and reports once', () async {
    await make().start();
    expect(opened, isEmpty, reason: 'no launch message on a warm app');

    openedStream.add(_message({'campaign_id': _campaign, 'dest': 'premium'}));
    await pumpEventQueue();

    expect(opened, [const PremiumLinkTarget(source: DeepLinkSource.push)]);
    expect(api.posts, ['/me/push-opened $_campaign']);
    expect(analytics.events, ['push_opened']);
  });

  test('a replayed launch message opens again but reports once', () async {
    final message = _message({'campaign_id': _campaign, 'dest': 'premium'});
    await make(initial: message).start();
    openedStream.add(message);
    await pumpEventQueue();

    expect(opened, hasLength(2));
    expect(api.posts, hasLength(1));
    expect(analytics.events, hasLength(1));
  });

  test('a foreground message is ignored', () async {
    await make().start();
    foregroundStream.add(
      _message({'campaign_id': _campaign, 'dest': 'premium'}),
    );
    await pumpEventQueue();

    expect(opened, isEmpty);
    expect(api.posts, isEmpty);
  });

  test('an unreadable payload opens the app and never throws', () async {
    await make(
      initial: _message({'campaign_id': _campaign, 'dest': 'horoscope'}),
    ).start();
    openedStream
      ..add(_message({'campaign_id': _campaign, 'dest': 'wallpaper'}))
      ..add(_message({'dest': 'ringtone', 'id': 'not-a-uuid'}))
      ..add(_message({}));
    await pumpEventQueue();

    expect(opened, isEmpty, reason: 'null target = home; the app is opening');
    expect(api.posts, [
      '/me/push-opened $_campaign',
    ], reason: 'a home open is still the campaign\'s open, counted once');
    expect(crash.errors, isEmpty);
  });

  test('a throwing onOpen is contained and recorded', () async {
    await make(
      initial: _message({'campaign_id': _campaign, 'dest': 'premium'}),
      onOpen: (_) => throw StateError('router gone'),
    ).start();

    expect(crash.errors, hasLength(1));
  });

  test(
    'a failing launch read is recorded and the warm path still works',
    () async {
      final handler = PushOpenHandler(
        apiClient: api,
        analytics: analytics,
        crash: crash,
        onOpen: opened.add,
        openedStream: openedStream.stream,
        foregroundStream: foregroundStream.stream,
        getInitialMessage: () async => throw Exception('no Play services'),
      );
      addTearDown(handler.dispose);
      await handler.start();
      expect(crash.errors, hasLength(1));

      openedStream.add(_message({'campaign_id': _campaign, 'dest': 'premium'}));
      await pumpEventQueue();
      expect(opened, hasLength(1));
    },
  );

  testWidgets('a cold tap is held on the splash until auth is decided', (
    tester,
  ) async {
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(path: '/', builder: (_, _) => const Text('splash')),
        GoRoute(path: '/sign-in', builder: (_, _) => const Text('sign-in')),
        GoRoute(path: '/browse', builder: (_, _) => const Text('feed')),
        GoRoute(path: '/ringtones', builder: (_, _) => const Text('ringtones')),
        GoRoute(path: '/premium', builder: (_, _) => const Text('premium')),
      ],
    );
    final taps = PushTapRouter(router: router, onSelectCategory: (_) {});
    addTearDown(taps.dispose);
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    await tester.runAsync(
      () => make(
        initial: _message({'campaign_id': _campaign, 'dest': 'premium'}),
        onOpen: taps.open,
      ).start(),
    );
    await tester.pumpAndSettle();
    expect(find.text('splash'), findsOneWidget);

    router.go('/sign-in'); // no session
    await tester.pumpAndSettle();
    expect(find.text('sign-in'), findsOneWidget);
    expect(find.text('premium'), findsNothing);

    router.go('/browse'); // signed in
    await tester.pumpAndSettle();
    expect(find.text('premium'), findsOneWidget);
    expect(api.posts, hasLength(1));
  });
}

class _RecordingApi extends ApiClient {
  final List<String> posts = [];

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Map<String, dynamic>? body,
    bool requiresAuth = true,
  }) async {
    posts.add('$path ${body?['campaign_id']}');
    return {'ok': true};
  }
}

class _RecordingCrash implements CrashReporter {
  final List<Object> errors = [];

  @override
  void recordError(
    Object error,
    StackTrace? stack, {
    String? reason,
    bool fatal = false,
  }) => errors.add(error);

  @override
  void setUserId(String? id) {}

  @override
  void log(String message) {}

  @override
  void setCustomKey(String key, Object value) {}
}

class _RecordingAnalytics implements AnalyticsService {
  final List<String> events = [];

  @override
  void track(String event, {Map<String, Object?>? properties}) =>
      events.add(event);

  @override
  void identify(String userId, {Map<String, Object?>? userProperties}) {}

  @override
  void screen(String name, {Map<String, Object?>? properties}) {}

  @override
  void reset() {}

  @override
  void register(String key, Object value) {}
}
