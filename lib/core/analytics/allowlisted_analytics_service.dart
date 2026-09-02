import 'analytics_service.dart';

/// Forwards only an explicit allow-list of events to the wrapped service.
///
/// **Default-deny, deliberately** -> a new `track()` call site costs nothing until it is listed here.
/// GA4 is wrapped separately and never passes through this decorator -> it still gets 100%.
/// Pairs with `AnalyticsCohort`: that gate decides WHO sends, this one narrows WHAT a member sends.
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

  /// Always forwards — person linkage is what makes the panel's funnels resolvable to a user.
  @override
  void identify(String userId, {Map<String, Object?>? userProperties}) =>
      _inner.identify(userId, userProperties: userProperties);

  /// Dropped: GA4 auto-collects `screen_view` at 100% for free -> a PostHog copy is duplicate volume.
  /// Nothing calls this today -> the empty override keeps that true if a call site appears.
  @override
  void screen(String name, {Map<String, Object?>? properties}) {}

  /// `reset()` on sign-out is SDK state correctness, not telemetry -> always forwards.
  /// Skipping it leaks one user's events onto the next user's distinct_id on a shared device.
  @override
  void reset() => _inner.reset();
}
