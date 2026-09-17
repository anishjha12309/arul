import 'package:arul/core/analytics/analytics_service.dart';
import 'package:arul/core/analytics/posthog_analytics_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The fresh-install window: `setup()` is fire-and-forget, so the sheet-first `login_attempt` can be
/// captured before the Dart `register` round trip lands. The SDK then stamps nothing -> the value
/// must ride on the capture itself. These tests drive the real plugin over a mocked method channel
/// (`posthog_flutter` allows every platform under FLUTTER_TEST).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('posthog_flutter');
  late List<MethodCall> calls;

  setUp(() {
    PostHogAnalyticsService.resetForTest();
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    PostHogAnalyticsService.resetForTest();
  });

  Map<String, Object?> captured(String event) {
    final call = calls.singleWhere(
      (c) => c.method == 'capture' && c.arguments['eventName'] == event,
    );
    return Map<String, Object?>.from(call.arguments['properties'] as Map);
  }

  test('a capture before started() carries the primed language', () async {
    PostHogAnalyticsService.prime({kAppLanguageProperty: 'ta'});
    const PostHogAnalyticsService().track(
      'login_attempt',
      properties: {'surface': 'sheet'},
    );
    await Future<void>.delayed(Duration.zero);
    expect(captured('login_attempt'), {
      kAppLanguageProperty: 'ta',
      'surface': 'sheet',
    });
    // Nothing was pushed to the SDK yet: prime() is Dart-side only.
    expect(calls.where((c) => c.method == 'register'), isEmpty);
  });

  test(
    'register() before started() wins over prime() and rides the capture',
    () async {
      const svc = PostHogAnalyticsService();
      svc.register(kAppLanguageProperty, 'hi');
      PostHogAnalyticsService.prime({kAppLanguageProperty: 'en'});
      svc.track('login_attempt');
      await Future<void>.delayed(Duration.zero);
      expect(captured('login_attempt'), {kAppLanguageProperty: 'hi'});
    },
  );

  test('the event\'s own property overrides a registered one', () async {
    PostHogAnalyticsService.prime({kAppLanguageProperty: 'ta'});
    const PostHogAnalyticsService().track(
      'deep_link_opened',
      properties: {kAppLanguageProperty: 'kn'},
    );
    await Future<void>.delayed(Duration.zero);
    expect(captured('deep_link_opened'), {kAppLanguageProperty: 'kn'});
  });

  test('started() pushes the primed value into the SDK once', () async {
    PostHogAnalyticsService.prime({kAppLanguageProperty: 'ta'});
    await PostHogAnalyticsService.started();
    final registers = calls.where((c) => c.method == 'register').toList();
    expect(registers, hasLength(1));
    expect(registers.single.arguments, {
      'key': kAppLanguageProperty,
      'value': 'ta',
    });
  });
}
