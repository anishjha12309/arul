import 'dart:async';

import 'package:posthog_flutter/posthog_flutter.dart';

import 'analytics_service.dart';

/// Real [AnalyticsService] backed by PostHog.
///
/// `Posthog().setup(...)` runs in `main()` -> this class only forwards onto that singleton.
/// Chosen over [NoOpAnalyticsService] only when a real project key is present
/// (`analytics_provider.dart`) -> tests and key-less dev builds stay offline.
/// The SDK queues and batch-uploads in the background -> fire-and-forget, never awaited on the UI path.
class PostHogAnalyticsService implements AnalyticsService {
  const PostHogAnalyticsService();

  @override
  void track(String event, {Map<String, Object?>? properties}) {
    unawaited(
      Posthog().capture(eventName: event, properties: _clean(properties)),
    );
  }

  @override
  void identify(String userId, {Map<String, Object?>? userProperties}) {
    unawaited(
      Posthog().identify(
        userId: userId,
        userProperties: _clean(userProperties),
      ),
    );
  }

  @override
  void screen(String name, {Map<String, Object?>? properties}) {
    unawaited(
      Posthog().screen(screenName: name, properties: _clean(properties)),
    );
  }

  @override
  void reset() => unawaited(Posthog().reset());

  /// The SDK takes `Map<String, Object>` but our interface allows nulls -> drop null entries.
  /// An empty or absent map -> `null`, never `{}`.
  Map<String, Object>? _clean(Map<String, Object?>? props) {
    if (props == null) return null;
    final out = <String, Object>{};
    props.forEach((key, value) {
      if (value != null) out[key] = value;
    });
    return out.isEmpty ? null : out;
  }
}
