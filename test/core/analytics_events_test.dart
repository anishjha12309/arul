// Pins the ★ event names. Every one is matched on the LITERAL string by an
// external system — PostHog insights, GA4 key events, the Google Ads
// conversion import, Meta's StartTrial mapping — so renaming a constant renames
// the event everywhere at once, which none of them can follow. A failure here
// means a dashboard or a bid is about to go dark.

import 'package:flutter_test/flutter_test.dart';

import 'package:arul/core/analytics/analytics_events.dart';
import 'package:arul/core/analytics/analytics_provider.dart';

void main() {
  test('★ event names are frozen', () {
    expect(ArulEvents.loginSuccess, 'login_success');
    expect(ArulEvents.wallpaperApplied, 'wallpaper_applied');
    expect(ArulEvents.wallpaperShared, 'wallpaper_shared');
    expect(ArulEvents.ringtoneSet, 'ringtone_set');
    expect(ArulEvents.trialStarted, 'trial_started');
    expect(ArulEvents.subscriptionActive, 'subscription_active');
    expect(ArulEvents.applicationInstalled, 'Application Installed');
  });

  test('the PostHog allow-list is exactly the five journey events', () {
    expect(postHogAllowedEvents, {
      'login_success',
      'wallpaper_applied',
      'wallpaper_shared',
      'ringtone_set',
      'trial_started',
      // TEMPORARY (2026-08-30 sign-in diagnosis) — see analytics_provider.dart.
      'login_cancelled',
      'login_failed',
    });
  });
}
