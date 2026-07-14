import 'dart:async';

import 'package:posthog_flutter/posthog_flutter.dart';

import 'analytics_service.dart';

/// Real [AnalyticsService] backed by PostHog.
///
/// Assumes `Posthog().setup(...)` has already run in `main()` — this class only
/// forwards events onto the configured singleton. It is selected over
/// [NoOpAnalyticsService] only when a real project key is present (see
/// `analytics_provider.dart`), so tests and key-less dev builds stay offline.
///
/// All calls are fire-and-forget: the SDK queues + batch-uploads in the
/// background, so we never block the caller (or await on the UI path).
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

  /// The SDK's maps are `Map<String, Object>` (non-null values), but our
  /// interface allows nullable values for caller convenience. Drop null entries
  /// and return null for an empty/absent map.
  Map<String, Object>? _clean(Map<String, Object?>? props) {
    if (props == null) return null;
    final out = <String, Object>{};
    props.forEach((key, value) {
      if (value != null) out[key] = value;
    });
    return out.isEmpty ? null : out;
  }
}
