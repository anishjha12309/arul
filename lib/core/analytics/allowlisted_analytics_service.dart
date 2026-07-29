import 'analytics_service.dart';

/// Forwards only an explicit allow-list of events to the wrapped service.
///
/// **Default-deny, deliberately.** This replaced a sample-rate map in which an
/// unlisted event forwarded at 100%, so every new `track()` call site silently
/// added billable PostHog volume unless someone remembered to also add a rate
/// for it. Inverting the default makes the cheap thing automatic: a new event
/// costs nothing in PostHog until it is consciously added here, while GA4
/// (wrapped separately, never through this decorator) still receives it at 100%
/// for free. Nothing is lost overall — only PostHog's billed copy is trimmed.
///
/// Pairs with `AnalyticsCohort`, which decides whether this install talks to
/// PostHog at all. This class narrows WHAT a panel member sends; the cohort gate
/// decides WHO sends. The cohort gate is the one doing the heavy lifting on
/// cost; this one keeps the panel's event stream focused on events a product
/// decision actually rides on.
class AllowlistedAnalyticsService implements AnalyticsService {
  const AllowlistedAnalyticsService(this._inner, {required this.allowed});

  final AnalyticsService _inner;

  /// Event names PostHog is permitted to receive. Everything else is dropped.
  final Set<String> allowed;

  @override
  void track(String event, {Map<String, Object?>? properties}) {
    if (!allowed.contains(event)) return;
    _inner.track(event, properties: properties);
  }

  /// Always forwards — person linkage is what makes the panel's funnels and
  /// retention resolvable to a user, which is the entire point of the panel.
  @override
  void identify(String userId, {Map<String, Object?>? userProperties}) =>
      _inner.identify(userId, userProperties: userProperties);

  /// Dropped. GA4 auto-collects `screen_view` for every screen, at 100%, for
  /// free, so a PostHog copy is pure duplicate billed volume. Nothing calls this
  /// today; the empty override keeps that true if a call site ever appears.
  @override
  void screen(String name, {Map<String, Object?>? properties}) {}

  /// Always forwards — `reset()` on sign-out is SDK state correctness, not
  /// telemetry, and skipping it would leak one user's events onto the next
  /// user's distinct_id on a shared device.
  @override
  void reset() => _inner.reset();
}
