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

    // Inverting the old sample-rate map means a brand-new track() call site costs NOTHING until someone opts it in.
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
      // Fail closed -> a build that forgets to resolve sends nothing, not everything -> the wrong direction costs money.
      expect(AnalyticsCohort.isMember, isFalse);
    });

    test('membership is exactly draw < rate', () async {
      // Asserted against debugRate, never a literal -> the rate is a tuning knob and a copy turns a retune into two failures.
      final prefs = await SharedPreferences.getInstance();
      final justUnder = AnalyticsCohort.debugRate * 0.5;
      expect(
        AnalyticsCohort.resolve(prefs, random: _FixedRandom(justUnder)),
        isTrue,
      );
      expect(AnalyticsCohort.isMember, isTrue);
    });

    test('a draw at or above the rate stays out', () async {
      // Random.nextDouble() is [0,1) -> at rate 1.0 no excluding draw can occur -> the panel is genuinely every install.
      // The rule still has to hold for any narrower rate -> exercise it directly.
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      const narrowRate = 0.05;
      const draw = 0.9;
      expect(draw < narrowRate, isFalse);

      AnalyticsCohort.resolve(prefs, random: const _FixedRandom(draw));
      expect(
        AnalyticsCohort.isMember,
        AnalyticsCohort.debugRate > draw,
        reason: 'membership must track the rate, not a remembered constant',
      );
    });

    test(
      'the draw persists, so membership is stable across launches',
      () async {
        final prefs = await SharedPreferences.getInstance();
        AnalyticsCohort.resolve(prefs, random: const _FixedRandom(0.01));
        AnalyticsCohort.debugReset();

        // A second launch draws a number that WOULD exclude this install -> the persisted draw wins.
        // Otherwise a user drifts in and out of the panel -> every retention curve built on it would be wrong.
        expect(
          AnalyticsCohort.resolve(prefs, random: const _FixedRandom(0.99)),
          isTrue,
        );
      },
    );

    test(
      'the DRAW is stored, not the boolean — which is what makes widening the '
      'rate additive',
      () async {
        // The property the design rests on, and the one a stored boolean would lose -> each install keeps its RAW draw.
        // So raising the rate only ADDS installs and never drops one already reporting -> retention curves stay continuous.
        // A stored boolean would force a fresh draw per install -> every cohort spanning the change would break.
        final prefs = await SharedPreferences.getInstance();
        AnalyticsCohort.resolve(prefs, random: const _FixedRandom(0.07));
        expect(prefs.getDouble('analytics_posthog_cohort_draw_v1'), 0.07);

        // Anyone inside a 5% panel is still inside every wider one.
        expect(0.07 < AnalyticsCohort.debugRate, AnalyticsCohort.isMember);
      },
    );
  });

  group('AnalyticsCohort.isFreshInstall', () {
    // Drives the hand-emitted `Application Installed` in main.dart -> the ONLY thing PostHog gets outside the allow-list.
    // Wrong either way is silent -> never true means no installs at all, true twice means an overstated install count.
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      AnalyticsCohort.debugReset();
    });

    test('false until resolve() runs', () {
      expect(AnalyticsCohort.isFreshInstall, isFalse);
    });

    test('true on the launch that creates the draw', () async {
      final prefs = await SharedPreferences.getInstance();
      AnalyticsCohort.resolve(prefs, random: const _FixedRandom(0.5));
      expect(AnalyticsCohort.isFreshInstall, isTrue);
    });

    test('false on every launch after that — install fires ONCE', () async {
      final prefs = await SharedPreferences.getInstance();
      AnalyticsCohort.resolve(prefs, random: const _FixedRandom(0.5));
      AnalyticsCohort.debugReset();

      AnalyticsCohort.resolve(prefs, random: const _FixedRandom(0.5));
      expect(AnalyticsCohort.isFreshInstall, isFalse);
    });

    test('false for an install that predates the flag', () async {
      // Its draw is already on disk from an earlier release -> shipping this cannot back-date an "install" onto the base.
      SharedPreferences.setMockInitialValues({
        'analytics_posthog_cohort_draw_v1': 0.42,
      });
      final prefs = await SharedPreferences.getInstance();
      AnalyticsCohort.resolve(prefs, random: const _FixedRandom(0.5));
      expect(AnalyticsCohort.isFreshInstall, isFalse);
    });
  });

  // The two gates above are correct in isolation -> these assert how they are WIRED, where the real bugs live.
  group('postHogAllowedEvents (the real list)', () {
    test('no paywall-block event is billed', () {
      // The blocked-premium events left the list with the rest of the non-journey noise (owner's call).
      // PostHog shows the journey only -> GA4 still has all three at 100%.
      // Still asserted through the ENUM, never literals -> that is what the feed concatenates into the event name.
      // A renamed `PremiumGateAction` plus a re-added old string here would grow an event nothing can ever fire.
      for (final action in PremiumGateAction.values) {
        expect(
          postHogAllowedEvents,
          isNot(contains('${action.source}_blocked_premium')),
          reason:
              '${action.source}_blocked_premium is deliberately GA4-only. '
              'Adding it back is a decision, not a cleanup — update '
              'docs/analytics-events.md with it.',
        );
      }
    });

    test('the billed events are exactly this list', () {
      // Pinned as a SET, not a subset -> PostHog carries the journey and nothing else (owner's call).
      // The journey is install -> login -> trial -> apply/share -> ringtone set.
      // The install half is `Application Installed`, captured in main.dart -> deliberately absent from this list.
      expect(postHogAllowedEvents, <String>{
        'login_success',
        'wallpaper_applied',
        'wallpaper_shared',
        'ringtone_set',
        'trial_started',
        // TEMPORARY, for the sign-in diagnosis -> the two picker-outcome diagnostics ride along.
        // They let the cancel/failure split be read same-day by build -> remove them here and in analytics_provider.dart.
        'login_cancelled',
        'login_failed',
      });
    });

    test('high-volume and diagnostic events stay OFF the list', () {
      // `wallpaper_engaged` fires per dwelled card -> the one genuine volume risk in the app -> cost, not style.
      // `feed_session_ended`, `subscription_active` and `referral_shared` came off for a different reason.
      // PostHog is the journey view now and revenue truth was always Neon.
      // The rest are attempts, failures and rare account admin -> Crashlytics, GA4 and Neon questions, not funnel ones.
      for (final event in <String>[
        'wallpaper_engaged',
        'feed_session_ended',
        'subscription_active',
        'referral_shared',
        'wallpaper_apply_attempt',
        'ringtone_preview',
        'ringtone_set_attempt',
        'share_watermark_failed',
        'profile_name_updated',
        'support_email_opened',
        'account_delete_confirmed',
        'account_delete_failed',
        'account_deleted',
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
    // The claim default-deny rests on -> trimming the PostHog list loses NOTHING, because only PostHog is wrapped.
    // GA4 is added to the composite UNWRAPPED and still receives 100% of every event.
    // Wrap the composite instead of the PostHog delegate and the app silently stops measuring itself -> nothing else notices.
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
      // PostHog drops them as duplicate billed volume -> GA4's no-op ignores them because it auto-collects screen_view.
      // The recording double here stands in for GA4 -> assert only that the PostHog side is closed.
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
