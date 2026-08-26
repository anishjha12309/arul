/// The event names the business is keyed on. Every one is matched by an
/// external system on the LITERAL string — PostHog insights, GA4 key events,
/// the Google Ads conversion import (`trial_started`), Meta's StartTrial
/// mapping — so a typo at a call site is not a compile error: the PostHog
/// allow-list drops it silently (default-deny) and GA4 just grows a new, unbid
/// event. The names live here once; call sites and the sink mappings use the
/// constant. Diagnostics (`payment_failed`, `login_cancelled`, …) may stay
/// literals — nothing downstream is keyed on them.
///
/// Changing a VALUE renames the event everywhere at once, which is exactly what
/// the dashboards and the Ads import cannot follow. Treat the values as frozen;
/// `test/core/analytics_events_test.dart` pins them.
abstract final class ArulEvents {
  static const loginSuccess = 'login_success';
  static const wallpaperApplied = 'wallpaper_applied';
  static const wallpaperShared = 'wallpaper_shared';
  static const ringtoneSet = 'ringtone_set';
  static const trialStarted = 'trial_started';

  /// Client-side copy of a paid settle (GA4 only — not on the PostHog list;
  /// the Worker reports that one). Here because it shares the conversion path
  /// with [trialStarted].
  static const subscriptionActive = 'subscription_active';

  /// PostHog's own install event, re-emitted by hand from `main.dart`.
  static const applicationInstalled = 'Application Installed';
}
