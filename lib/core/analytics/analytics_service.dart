/// Single interface for all analytics events. `analyticsServiceProvider`
/// assembles the real backends behind it — PostHog, GA4 (Firebase) and Meta —
/// from whichever keys are configured; call sites never change.
abstract interface class AnalyticsService {
  void track(String event, {Map<String, Object?>? properties});
  void identify(String userId, {Map<String, Object?>? userProperties});
  void screen(String name, {Map<String, Object?>? properties});
  void reset();
}

/// No-op fallback, selected when no backend is configured: `flutter test`, CI,
/// and key-less dev builds send nothing.
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
