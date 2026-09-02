/// The event names the business is keyed on, matched by external systems on the LITERAL string.
///
/// A typo at a call site is not a compile error -> the allow-list drops it, GA4 grows an unbid event.
/// So the names live here once and every call site and sink mapping uses the constant.
/// Diagnostics (`payment_failed`, `login_cancelled`, …) may stay literals — nothing is keyed on them.
/// Changing a VALUE renames the event everywhere, which dashboards and the Ads import cannot follow.
/// Treat the values as FROZEN; `test/core/analytics_events_test.dart` pins them.
abstract final class ArulEvents {
  static const loginSuccess = 'login_success';
  static const wallpaperApplied = 'wallpaper_applied';
  static const wallpaperShared = 'wallpaper_shared';
  static const ringtoneSet = 'ringtone_set';
  static const trialStarted = 'trial_started';

  /// Client-side copy of a paid settle — GA4 only; the Worker reports the PostHog one.
  /// Here because it shares the conversion path with [trialStarted].
  static const subscriptionActive = 'subscription_active';

  /// PostHog's own install event, re-emitted by hand from `main.dart`.
  static const applicationInstalled = 'Application Installed';
}
