import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:arul/core/analytics/allowlisted_analytics_service.dart';
import 'package:arul/core/analytics/analytics_cohort.dart';
import 'package:arul/core/analytics/analytics_provider.dart';
import 'package:arul/core/analytics/analytics_service.dart';
import 'package:arul/core/analytics/composite_analytics_service.dart';
import 'package:arul/features/wallpapers/presentation/premium_gate_action.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Records every call so we can assert exactly what reached PostHog.
class _RecordingAnalyticsService implements AnalyticsService {
  final tracked = <String>[];
  final screens = <String>[];
  final identified = <String>[];
  int resets = 0;

  @override
  void track(String event, {Map<String, Object?>? properties}) =>
      tracked.add(event);

  @override
  void identify(String userId, {Map<String, Object?>? userProperties}) =>
      identified.add(userId);

  @override
  void screen(String name, {Map<String, Object?>? properties}) =>
      screens.add(name);

  @override
  void reset() => resets++;
}

/// Returns a fixed draw so cohort membership is deterministic in tests.
class _FixedRandom implements Random {
  const _FixedRandom(this._value);
  final double _value;

  @override
  double nextDouble() => _value;

  @override
  bool nextBool() => throw UnimplementedError();

  @override
  int nextInt(int max) => throw UnimplementedError();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AllowlistedAnalyticsService', () {
    late _RecordingAnalyticsService inner;
    late AllowlistedAnalyticsService svc;

    setUp(() {
      inner = _RecordingAnalyticsService();
      svc = AllowlistedAnalyticsService(
        inner,
        allowed: const {'wallpaper_applied', 'login_success'},
      );
    });

    test('forwards an allow-listed event', () {
      svc.track('wallpaper_applied', properties: {'id': 'w1'});
      expect(inner.tracked, ['wallpaper_applied']);
    });

    test('drops an event that is not on the list', () {
      svc.track('wallpaper_engaged');
      svc.track('ringtone_preview');
      expect(inner.tracked, isEmpty);
    });

    // The whole point of inverting the old sample-rate map: a brand-new track()
    // call site must cost nothing in PostHog until someone opts it in.
    test('a new, unknown event defaults to dropped', () {
      svc.track('some_feature_added_next_quarter');
      expect(inner.tracked, isEmpty);
    });

    test('drops screen views — GA4 auto-collects them for free', () {
      svc.screen('wallpapers');
      expect(inner.screens, isEmpty);
    });

    test('always forwards identify and reset (SDK state, not telemetry)', () {
      svc.identify('user-1');
      svc.reset();
      expect(inner.identified, ['user-1']);
      expect(inner.resets, 1);
    });
  });

  group('AnalyticsCohort', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      AnalyticsCohort.debugReset();
    });

    test('defaults to non-member before resolve() runs', () {
      // Fail closed: a build that forgets to resolve must send nothing rather
      // than everything, because the wrong direction here costs money.
      expect(AnalyticsCohort.isMember, isFalse);
    });

    test('a draw below the rate joins the panel', () async {
      final prefs = await SharedPreferences.getInstance();
      expect(
        AnalyticsCohort.resolve(prefs, random: const _FixedRandom(0.01)),
        isTrue,
      );
      expect(AnalyticsCohort.isMember, isTrue);
    });

    test('a draw above the rate stays out', () async {
      final prefs = await SharedPreferences.getInstance();
      expect(
        AnalyticsCohort.resolve(prefs, random: const _FixedRandom(0.9)),
        isFalse,
      );
      expect(AnalyticsCohort.isMember, isFalse);
    });

    test(
      'the draw persists, so membership is stable across launches',
      () async {
        final prefs = await SharedPreferences.getInstance();
        AnalyticsCohort.resolve(prefs, random: const _FixedRandom(0.01));
        AnalyticsCohort.debugReset();

        // Second launch draws a number that WOULD exclude this install, but the
        // persisted draw wins — otherwise a user would drift in and out of the
        // panel and every retention curve built on it would be wrong.
        expect(
          AnalyticsCohort.resolve(prefs, random: const _FixedRandom(0.99)),
          isTrue,
        );
      },
    );

    test(
      'storing the draw means widening the rate only ever adds installs',
      () async {
        // An install that drew 0.07 sits outside a 5% panel. If the rate is later
        // widened past 0.07 it joins — and crucially, nobody already inside is
        // ever dropped, because their draw is unchanged. This is the property a
        // stored boolean would lose.
        final prefs = await SharedPreferences.getInstance();
        AnalyticsCohort.resolve(prefs, random: const _FixedRandom(0.07));
        expect(prefs.getDouble('analytics_posthog_cohort_draw_v1'), 0.07);
        expect(AnalyticsCohort.isMember, isFalse);
      },
    );
  });

  // The two gates above are correct in isolation; these assert how they are
  // WIRED, which is where the money and the missing-event bugs actually live.
  group('postHogAllowedEvents (the real list)', () {
    test('the APPLY gate is the one blocked-premium event billed', () {
      // Only the apply gate is allow-listed (cost decision, 2026-07-29): it
      // carries the volume, and share/ringtone blocks describe the same funnel
      // shape. So the invariant is no longer "every gate is listed" — it is
      // "apply is listed, and the others are deliberately not".
      //
      // What this still guards: `PremiumGateAction.apply.source` is the string
      // the feed actually concatenates into the event name. If that enum value
      // is ever renamed, the event silently changes name, keeps flowing to GA4,
      // and vanishes from PostHog with nothing failing anywhere.
      final apply = PremiumGateAction.values.firstWhere(
        (a) => a.name == 'apply',
      );
      expect(
        postHogAllowedEvents,
        contains('${apply.source}_blocked_premium'),
        reason:
            'PremiumGateAction.apply fires "${apply.source}_blocked_premium", '
            'which is not allow-listed — the paywall funnel would lose its '
            'trigger. Fix the list or update docs/analytics-events.md.',
      );
    });

    test('the four billed events are exactly the list', () {
      // Pinned as a SET, not a subset: the whole point of the trim is that
      // adding a fifth event is a cost decision someone must make on purpose.
      expect(postHogAllowedEvents, <String>{
        'feed_session_ended',
        'wallpaper_applied',
        'apply_blocked_premium',
        'subscription_active',
      });
    });

    test('high-volume and diagnostic events stay OFF the list', () {
      // Not style — cost. `wallpaper_engaged` fires per dwelled card and is the
      // event `feed_session_ended` exists to replace; letting it back on the
      // list re-creates the bill that rollup was written to avoid. The rest are
      // answered better (and free) by GA4, Crashlytics or Neon.
      //
      // The second block is the 2026-07-29 cost trim: each of those WAS billed
      // and was dropped on purpose. They are asserted here so a well-meaning
      // "this event looks useful, let me add it back" is a failing test rather
      // than a silent line on the invoice.
      for (final event in <String>[
        'wallpaper_engaged',
        'wallpaper_apply_attempt',
        'ringtone_preview',
        'ringtone_set_attempt',
        'login_failed',
        'share_watermark_failed',
        'profile_name_updated',
        'support_email_opened',
        'account_delete_confirmed',
        'account_delete_failed',
        'account_deleted',
        // Dropped 2026-07-29 — in Neon and/or GA4 already.
        'login_success',
        'trial_started',
        'referral_shared',
        'wallpaper_shared',
        'ringtone_set',
        'share_blocked_premium',
        'ringtone_set_blocked_premium',
      ]) {
        expect(
          postHogAllowedEvents,
          isNot(contains(event)),
          reason:
              '$event is deliberately GA4-only (see docs/analytics-events.md). '
              'Adding it to the PostHog allow-list is a billing decision, not a '
              'cleanup.',
        );
      }
    });
  });

  group('fan-out asymmetry', () {
    // The claim the whole default-deny design rests on: trimming the PostHog
    // list loses NOTHING, because only PostHog is wrapped. GA4 is added to the
    // composite unwrapped and still receives 100% of every event. If someone
    // ever "tidies up" by wrapping the composite instead of the PostHog
    // delegate, the app silently stops measuring most of its own behaviour —
    // and no other test in either repo would notice.
    late _RecordingAnalyticsService posthog;
    late _RecordingAnalyticsService ga4;
    late CompositeAnalyticsService composite;

    setUp(() {
      posthog = _RecordingAnalyticsService();
      ga4 = _RecordingAnalyticsService();
      composite = CompositeAnalyticsService([
        AllowlistedAnalyticsService(posthog, allowed: postHogAllowedEvents),
        ga4,
      ]);
    });

    test('an allow-listed event reaches both backends', () {
      composite.track('wallpaper_applied');
      expect(posthog.tracked, ['wallpaper_applied']);
      expect(ga4.tracked, ['wallpaper_applied']);
    });

    test('a non-allow-listed event reaches GA4 only', () {
      composite.track('wallpaper_engaged');
      composite.track('ringtone_preview');
      expect(posthog.tracked, isEmpty);
      expect(ga4.tracked, ['wallpaper_engaged', 'ringtone_preview']);
    });

    test('screen views reach neither', () {
      // PostHog drops them (duplicate billed volume); GA4's own no-op
      // implementation ignores them because it auto-collects screen_view. The
      // recording double here stands in for GA4, so assert only the PostHog
      // side is closed.
      composite.screen('browse');
      expect(posthog.screens, isEmpty);
    });

    test('identify and reset reach both — SDK state, not telemetry', () {
      composite.identify('user-1');
      composite.reset();
      expect(posthog.identified, ['user-1']);
      expect(ga4.identified, ['user-1']);
      expect(posthog.resets, 1);
      expect(ga4.resets, 1);
    });
  });
}
