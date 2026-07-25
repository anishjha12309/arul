import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:arul/core/analytics/analytics_provider.dart';
import 'package:arul/core/analytics/analytics_service.dart';
import 'package:arul/core/analytics/composite_analytics_service.dart';

/// Records calls so we can assert fan-out / filtering without any real SDK.
class _RecordingAnalyticsService implements AnalyticsService {
  final tracked = <(String, Map<String, Object?>?)>[];
  final identified = <String>[];
  int resets = 0;

  @override
  void track(String event, {Map<String, Object?>? properties}) =>
      tracked.add((event, properties));

  @override
  void identify(String userId, {Map<String, Object?>? userProperties}) =>
      identified.add(userId);

  @override
  void screen(String name, {Map<String, Object?>? properties}) {}

  @override
  void reset() => resets++;
}

/// Throws on every call — used to prove the composite isolates a bad delegate.
class _ThrowingAnalyticsService implements AnalyticsService {
  @override
  void track(String event, {Map<String, Object?>? properties}) =>
      throw StateError('boom');
  @override
  void identify(String userId, {Map<String, Object?>? userProperties}) =>
      throw StateError('boom');
  @override
  void screen(String name, {Map<String, Object?>? properties}) =>
      throw StateError('boom');
  @override
  void reset() => throw StateError('boom');
}

void main() {
  group('analyticsServiceProvider', () {
    // Guards the real invariant: under `flutter test` none of the three
    // backends are configured, so the provider's switch must land on the
    // no-op and send nothing.
    test('provides NoOpAnalyticsService', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final svc = container.read(analyticsServiceProvider);
      expect(svc, isA<NoOpAnalyticsService>());
    });
  });

  group('CompositeAnalyticsService', () {
    test('track/identify/reset fan out to every delegate', () {
      final a = _RecordingAnalyticsService();
      final b = _RecordingAnalyticsService();
      final composite = CompositeAnalyticsService([a, b]);

      composite.track('trial_started', properties: {'value': 199.0});
      composite.identify('user-1');
      composite.reset();

      for (final svc in [a, b]) {
        expect(svc.tracked.single.$1, 'trial_started');
        expect(svc.tracked.single.$2, {'value': 199.0});
        expect(svc.identified.single, 'user-1');
        expect(svc.resets, 1);
      }
    });

    test('a throwing delegate does not stop the others', () {
      final good = _RecordingAnalyticsService();
      // Throwing delegate first, so the good one only runs if we isolate it.
      final composite = CompositeAnalyticsService([
        _ThrowingAnalyticsService(),
        good,
      ]);

      expect(() => composite.track('login_success'), returnsNormally);
      expect(good.tracked.single.$1, 'login_success');
    });
  });
}
