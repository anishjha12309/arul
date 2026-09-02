import 'analytics_service.dart';

/// Fans every [AnalyticsService] call out to a list of delegates.
///
/// Several SDKs must receive the same event -> fan out HERE -> the single `AnalyticsService` seam
/// holds (widgets never touch SDKs) and call sites stay identical. Delegates: `analyticsService`.
/// Each delegate filters for itself -> this one never decides who gets what.
/// One SDK throwing must not swallow another's event -> every call is wrapped; delegates are
/// fire-and-forget internally, so this only guards SYNCHRONOUS throws.
class CompositeAnalyticsService implements AnalyticsService {
  const CompositeAnalyticsService(this._delegates);

  final List<AnalyticsService> _delegates;

  void _forEach(void Function(AnalyticsService) action) {
    for (final delegate in _delegates) {
      try {
        action(delegate);
      } catch (_) {
        // Isolated on purpose -> one backend's failure never drops the event for the others, and
        // never bubbles onto the UI path.
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
