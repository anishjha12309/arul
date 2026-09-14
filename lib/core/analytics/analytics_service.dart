/// The app's UI language, registered on every event — same name as the person property `identify`
/// sets at sign-in, so a breakdown reads one column whichever scope it picks.
const kAppLanguageProperty = 'app_language';

/// Single interface for all analytics events.
/// `analyticsServiceProvider` assembles PostHog, GA4 and Meta behind it -> call sites never change.
abstract interface class AnalyticsService {
  void track(String event, {Map<String, Object?>? properties});
  void identify(String userId, {Map<String, Object?>? userProperties});
  void screen(String name, {Map<String, Object?>? properties});
  void reset();

  /// A property stamped on EVERY later event, not just on the person.
  /// A person property is frozen onto each event at ingest (person-on-events), so anything captured
  /// before `identify` carries none -> the sign-in funnel needs the value on the event itself.
  /// Survives [reset]: each sink re-applies what was registered, so a sign-out never strips it.
  void register(String key, Object value);
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

  @override
  void register(String key, Object value) {}
}
