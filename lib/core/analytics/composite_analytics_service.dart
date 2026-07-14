import 'analytics_service.dart';

/// Fans every [AnalyticsService] call out to a list of delegates.
///
/// Lets us keep the SINGLE `AnalyticsService` seam (CLAUDE.md §3 — widgets never
/// touch SDKs) while sending events to more than one backend. In practice the
/// delegates are PostHog (full product analytics) + Meta (★ conversion events
/// only; it filters internally). Call sites stay identical.
///
/// A throwing delegate must not stop the others: each call is wrapped so one
/// SDK's failure can't swallow another's event. Delegates are already
/// fire-and-forget internally, so this only guards synchronous throws.
class CompositeAnalyticsService implements AnalyticsService {
  const CompositeAnalyticsService(this._delegates);

  final List<AnalyticsService> _delegates;

  void _forEach(void Function(AnalyticsService) action) {
    for (final delegate in _delegates) {
      try {
        action(delegate);
      } catch (_) {
        // Isolate delegates: a failure in one backend must not drop the event
        // for the others (or bubble onto the UI path).
      }
    }
  }

  @override
  void track(String event, {Map<String, Object?>? properties}) =>
      _forEach((d) => d.track(event, properties: properties));

  @override
  void identify(String userId, {Map<String, Object?>? userProperties}) =>
      _forEach((d) => d.identify(userId, userProperties: userProperties));

  @override
  void screen(String name, {Map<String, Object?>? properties}) =>
      _forEach((d) => d.screen(name, properties: properties));

  @override
  void reset() => _forEach((d) => d.reset());
}
