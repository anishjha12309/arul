/// Single interface for all analytics events. Phase 12 swaps in the real
/// PostHog + Meta implementations; everything else stays unchanged.
abstract interface class AnalyticsService {
  void track(String event, {Map<String, Object?>? properties});
  void identify(String userId, {Map<String, Object?>? userProperties});
  void screen(String name, {Map<String, Object?>? properties});
  void reset();
}

/// No-op implementation used during development (Phases 0–11).
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
