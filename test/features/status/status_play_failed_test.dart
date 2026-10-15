// A clip the player gave up on is always a GA4 event; only a fault worth fixing is a Crashlytics
// record — a dropped or timed-out connection is the phone's network, not a bug.
import 'package:arul/core/analytics/analytics_provider.dart';
import 'package:arul/core/analytics/analytics_service.dart';
import 'package:arul/core/crash/crash_provider.dart';
import 'package:arul/core/crash/crash_reporter.dart';
import 'package:arul/features/status/domain/status_video.dart';
import 'package:arul/features/status/providers/status_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _clip = StatusVideo(
  id: 'c0ffee02-1c2d-4f3a-9b8e-7d6c5a4b3e2f',
  title: 'Amman',
  category: 'tamil',
  key: 'statuses/tamil/c0ffee02.mp4',
  width: 768,
  height: 1152,
);

class _RecordingAnalytics implements AnalyticsService {
  final events = <(String, Map<String, Object?>?)>[];

  @override
  void track(String event, {Map<String, Object?>? properties}) =>
      events.add((event, properties));

  @override
  void identify(String userId, {Map<String, Object?>? userProperties}) {}

  @override
  void screen(String name, {Map<String, Object?>? properties}) {}

  @override
  void reset() {}

  @override
  void register(String key, Object value) {}
}

class _RecordingCrash extends NoOpCrashReporter {
  final reasons = <String?>[];
  final logs = <String>[];

  @override
  void recordError(
    Object error,
    StackTrace? stack, {
    String? reason,
    bool fatal = false,
  }) => reasons.add(reason);

  @override
  void log(String message) => logs.add(message);
}

void main() {
  // The controller watches the app lifecycle through WidgetsBinding.
  TestWidgetsFlutterBinding.ensureInitialized();

  late _RecordingAnalytics analytics;
  late _RecordingCrash crash;

  void giveUp(String code) {
    analytics = _RecordingAnalytics();
    crash = _RecordingCrash();
    final c = ProviderContainer.test(
      overrides: [
        analyticsServiceProvider.overrideWithValue(analytics),
        crashReporterProvider.overrideWithValue(crash),
      ],
    );
    c.read(statusVideoControllerProvider).onGaveUp!(_clip, code);
  }

  test('a dropped connection is an event with reason network, no crash', () {
    giveUp('ERROR_CODE_IO_NETWORK_CONNECTION_FAILED');
    expect(analytics.events.single.$1, 'status_play_failed');
    expect(analytics.events.single.$2, {
      'status_id': _clip.id,
      'category': 'tamil',
      'code': 'ERROR_CODE_IO_NETWORK_CONNECTION_FAILED',
      'reason': 'network',
    });
    expect(crash.reasons, isEmpty);
    expect(crash.logs, hasLength(1));
  });

  test('a timed-out connection is network too', () {
    giveUp('ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT');
    expect(analytics.events.single.$2!['reason'], 'network');
    expect(crash.reasons, isEmpty);
  });

  test('a decoder failure is an event and a crash record', () {
    giveUp('ERROR_CODE_DECODER_INIT_FAILED');
    expect(analytics.events.single.$1, 'status_play_failed');
    expect(
      analytics.events.single.$2!['reason'],
      'ERROR_CODE_DECODER_INIT_FAILED',
    );
    expect(crash.reasons, ['status play failed']);
  });
}
