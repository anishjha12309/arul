/// Single interface for all analytics events.
/// `analyticsServiceProvider` assembles PostHog, GA4 and Meta behind it -> call sites never change.
abstract interface class AnalyticsService {
  void track(String event, {Map<String, Object?>? properties});
  void identify(String userId, {Map<String, Object?>? userProperties});
  void screen(String name, {Map<String, Object?>? properties});
  void reset();
}

/// No-op fallback when no backend is configured -> `flutter test`, CI and key-less builds send nothing.
class NoOpAnalyticsService implements AnalyticsService {
  const NoOpAnalyticsService();

  @override
  void track(String event, {Map<String, Object?>? properties}) {}

  @override
  void identify(String userId, {Map<String, Object?>? userProperties}) {}

  @override
  void screen(String name, {Map<String, Object?>? properties}) {}

  @override
  void reset() {}
}
