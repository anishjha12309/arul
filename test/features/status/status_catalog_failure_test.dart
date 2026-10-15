// Riverpod retries a failed catalog build and keeps the error on each retry's loading state, so a
// failure is reported on the first error only, never once per retry.
import 'dart:io';

import 'package:arul/core/analytics/analytics_provider.dart';
import 'package:arul/core/analytics/analytics_service.dart';
import 'package:arul/core/crash/crash_provider.dart';
import 'package:arul/core/crash/crash_reporter.dart';
import 'package:arul/data/catalog/catalog_http_client.dart';
import 'package:arul/data/repositories/repository_providers.dart';
import 'package:arul/features/status/providers/status_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _RecordingAnalytics implements AnalyticsService {
  final events = <String>[];
  final props = <Map<String, Object?>?>[];

  @override
  void track(String event, {Map<String, Object?>? properties}) {
    events.add(event);
    props.add(properties);
  }

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

  @override
  void recordError(
    Object error,
    StackTrace? stack, {
    String? reason,
    bool fatal = false,
  }) => reasons.add(reason);
}

void main() {
  late _RecordingAnalytics analytics;
  late _RecordingCrash crash;
  late int calls;

  setUp(() {
    analytics = _RecordingAnalytics();
    crash = _RecordingCrash();
    calls = 0;
  });

  /// Loads the catalog against [respond] until it settles on an error, retrying up to twice.
  Future<void> loadFailing(Future<http.Response> Function() respond) async {
    final c = ProviderContainer(
      retry: (retryCount, error) => retryCount < 2 ? Duration.zero : null,
      overrides: [
        catalogHttpClientProvider.overrideWithValue(
          CatalogHttpClient(
            cdnBaseUrl: 'https://cdn.test',
            client: MockClient((_) {
              calls++;
              return respond();
            }),
          ),
        ),
        analyticsServiceProvider.overrideWithValue(analytics),
        crashReporterProvider.overrideWithValue(crash),
      ],
    );
    addTearDown(c.dispose);
    c.listen(statusCatalogProvider, (_, _) {});
    for (var i = 0; i < 200; i++) {
      final s = c.read(statusCatalogProvider);
      if (s.hasError && !s.isLoading) return;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    fail('the catalog never settled on an error');
  }

  test('offline across every retry -> one network event, no crash', () async {
    await loadFailing(() async => throw const SocketException('down'));

    expect(calls, 3, reason: 'the first build and two retries');
    expect(analytics.events, ['status_load_failed']);
    expect(analytics.props, [
      {'reason': 'network'},
    ]);
    expect(crash.reasons, isEmpty);
  });

  test('page 1 missing on the CDN -> one event and a crash record', () async {
    await loadFailing(() async => http.Response('', 404));

    expect(analytics.events, ['status_load_failed']);
    expect(analytics.props, [
      {'reason': 'StateError'},
    ]);
    expect(crash.reasons, ['status catalog load failed']);
  });
}
