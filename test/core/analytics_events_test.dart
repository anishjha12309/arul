// Every ★ event name is matched on the LITERAL string by an external system.
// PostHog insights, GA4 key events, the Ads conversion import and Meta's StartTrial all key on it.
// Renaming a constant renames the event everywhere at once -> a failure here means a dashboard or a bid goes dark.

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
      // TEMPORARY, added for the sign-in diagnosis -> see analytics_provider.dart.
      'login_cancelled',
      'login_failed',
    });
  });
}
