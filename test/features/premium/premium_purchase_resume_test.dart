// Coming back from the UPI app is NOT a decision -> the mandate is still open at PhonePe and the
// user gets it back, they do not lose it.
//
// 84.4% of failed setups die as INTENT_EXPIRED: the approval sheet was reached and not approved.
// The old checkpoint abandoned on that return, which REVOKED a mandate the user could still have
// approved. So: return with the order open -> `PurchaseResumable`, zero abandons, the SAME link one
// tap away until the order's own deadline, which then retires it silently — no button to find.
//
// The three counts are what this file really asserts, because each one is a way to lose money:
//   • `/payments/abandon` — one per attempt, and only when another app or the clock ends it;
//   • `/payments/initiate` — NEVER from a resume; a second one revokes the live order;
//   • `checkout_started` — one per decision, never per launch (it is ★ in GA4 and Meta).
//
// Time is faked through `PremiumPurchase.clock` -> the deadline is wall-clock by design (Android
// freezes a backgrounded process and every Dart timer with it), so the tests own the wall clock.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:arul/core/analytics/analytics_provider.dart';
import 'package:arul/core/analytics/analytics_service.dart';
import 'package:arul/core/api/api_client.dart';
import 'package:arul/core/providers/shared_preferences_provider.dart';
import 'package:arul/data/models/app_config_model.dart';
import 'package:arul/data/repositories/repository_providers.dart';
import 'package:arul/features/auth/providers/auth_providers.dart';
import 'package:arul/features/premium/domain/trial_nudge.dart';
import 'package:arul/features/premium/providers/premium_purchase_provider.dart';
import 'package:arul/features/premium/providers/trial_conversion_catch_up.dart';

class _RecordingAnalytics implements AnalyticsService {
  final events = <(String, Map<String, Object?>?)>[];

  @override
  void track(String event, {Map<String, Object?>? properties}) =>
      events.add((event, properties));

  @override
  void identify(String userId, {Map<String, Object?>? userProperties}) {}

  @override
  void screen(String name, {Map<String, Object?>? properties}) {}

  @override
  void reset() {}

  @override
  void register(String key, Object value) {}
}

/// Answers the three purchase endpoints in memory -> `/payments/status` walks [statuses] and repeats
/// the last one forever, which is what a mandate nobody ever approves actually does.
class _FakeApi extends ApiClient {
  _FakeApi(this.statuses, {required this.intentUrl});

  final List<String> statuses;
  final String intentUrl;

  int initiates = 0;
  int statusCalls = 0;
  int abandons = 0;

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Map<String, dynamic>? body,
    bool requiresAuth = true,
  }) async {
    switch (path) {
      case '/payments/initiate':
        initiates++;
        return {'merchantOrderId': 'DKS_ORDER_1', 'intentUrl': intentUrl};
      case '/payments/status':
        final i = statusCalls++;
        return {
          'status': statuses[i < statuses.length ? i : statuses.length - 1],
        };
      case '/payments/abandon':
        abandons++;
        return {'settled': false};
    }
    throw StateError('unexpected POST $path');
  }
}

const _upiChannel = MethodChannel('com.hsrutility.arul/upi_intent');
const _phonePe = 'com.phonepe.app';
const _gpay = 'com.google.android.apps.nbu.paisa.user';

/// A link with no `QRexpire` — sandbox `ppesim://` links have none, so the fallback window runs.
const _noExpiryUrl = 'upi://mandate?tr=DKS_ORDER_1&am=2';

/// PhonePe writes the deadline into the link itself, ISO-8601 with an offset and NANOSECONDS.
/// Rendered from [at] so the test never has to know the fake clock's epoch.
String _urlExpiringAt(DateTime at) {
  // +05:30 is what production carries, written UNENCODED — the trap the parser exists for — and the
  // fraction is padded to nine digits, which is what PhonePe writes and what `DateTime` truncates.
  final t = at.toUtc().add(const Duration(hours: 5, minutes: 30));
  String two(int v) => v.toString().padLeft(2, '0');
  final nanos = (t.millisecond * 1000 + t.microsecond).toString().padLeft(
    6,
    '0',
  );
  final iso =
      '${t.year}-${two(t.month)}-${two(t.day)}T'
      '${two(t.hour)}:${two(t.minute)}:${two(t.second)}.${nanos}000+05:30';
  return 'upi://mandate?tr=DKS_ORDER_1&QRts=$iso&QRexpire=$iso&am=2';
}

void main() {
  late _RecordingAnalytics analytics;
  late SharedPreferences prefs;
  late List<Map<Object?, Object?>> launches;
  late bool launchSucceeds;

  Future<ProviderContainer> build(
    WidgetTester tester,
    _FakeApi api, {
    List<Override> overrides = const [],
  }) async {
    SharedPreferences.setMockInitialValues(const {});
    prefs = await SharedPreferences.getInstance();
    analytics = _RecordingAnalytics();
    launches = [];
    launchSucceeds = true;
    // The mandate's deadline is a wall-clock fact -> hand the notifier the FAKE wall clock, the one
    // `tester.pump(duration)` moves. Real `DateTime.now()` would never reach any deadline in a test.
    PremiumPurchase.clock = () => tester.binding.clock.now();
    addTearDown(() => PremiumPurchase.clock = DateTime.now);

    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      _upiChannel,
      (call) async {
        if (call.method != 'launch') return null;
        launches.add(call.arguments as Map<Object?, Object?>);
        return launchSucceeds;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        _upiChannel,
        null,
      ),
    );

    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        apiClientProvider.overrideWith((ref) => api),
        analyticsServiceProvider.overrideWith((ref) => analytics),
        appConfigProvider.overrideWithBuild(
          (ref, _) async => const AppConfigModel(
            prices: {
              'monthly': {'amount': 19900},
            },
            policyUrls: <String, dynamic>{},
            featureFlags: <String, dynamic>{},
          ),
        ),
        trialConversionCatchUpProvider.overrideWithValue(
          TrialConversionCatchUp(
            prefs: prefs,
            analytics: analytics,
            monthlyPriceRupees: () => 199,
          ),
        ),
        ...overrides,
      ],
    );
    addTearDown(container.dispose);
    // The paywall is OPEN throughout: this whole feature is a button, and a button needs a screen.
    final sub = container.listen(premiumPurchaseProvider, (_, _) {});
    addTearDown(sub.close);
    await container.read(appConfigProvider.future);
    return container;
  }

  List<Map<String, Object?>?> eventsNamed(String name) =>
      analytics.events.where((e) => e.$1 == name).map((e) => e.$2).toList();

  /// Tap the trial CTA, then come back from the UPI app without approving.
  Future<void> launchThenReturn(
    WidgetTester tester,
    ProviderContainer container,
  ) async {
    unawaited(
      container
          .read(premiumPurchaseProvider.notifier)
          .startTrial(targetApp: _phonePe, trialEligible: true),
    );
    await tester.pump(const Duration(milliseconds: 10));
    unawaited(
      container.read(premiumPurchaseProvider.notifier).pollNowOnResume(),
    );
    await tester.pump(const Duration(milliseconds: 200));
  }

  /// Ends whatever is still watching, so no test leaves a timer behind.
  /// Past the fallback window the watch abandons and stops by itself.
  Future<void> drain(WidgetTester tester) =>
      tester.pump(const Duration(minutes: 20));

  // ─── The deadline ─────────────────────────────────────────────────────────

  group('intent expiry', () {
    test('QRexpire is read off the link, nanoseconds and offset included', () {
      // PhonePe's own sample, verbatim: 9 fraction digits and an unencoded +05:30.
      final parsed = PremiumPurchase.parseIntentExpiry(
        'upi://mandate?pa=x&QRts=2026-04-14T11:11:11.582158634+05:30'
        '&QRexpire=2026-04-14T11:26:11.582158634+05:30&am=2',
      );
      expect(parsed?.toUtc(), DateTime.utc(2026, 4, 14, 5, 56, 11, 582, 158));
    });

    test('a percent-encoded link reads the same', () {
      final parsed = PremiumPurchase.parseIntentExpiry(
        'upi://mandate?QRexpire=2026-04-14T11%3A26%3A11.582158634%2B05%3A30',
      );
      expect(parsed?.toUtc(), DateTime.utc(2026, 4, 14, 5, 56, 11, 582, 158));
    });

    test('no QRexpire at all -> null, and the caller falls back', () {
      expect(PremiumPurchase.parseIntentExpiry(_noExpiryUrl), isNull);
      expect(PremiumPurchase.parseIntentExpiry('ppesim://mandate'), isNull);
      final launchedAt = DateTime.utc(2026, 4, 14, 11);
      expect(
        PremiumPurchase.intentExpiry(_noExpiryUrl, launchedAt),
        launchedAt.add(const Duration(minutes: 10)),
      );
    });

    test('a deadline past PhonePe\'s documented 15 min maximum is capped', () {
      final launchedAt = DateTime.utc(2026, 4, 14, 11);
      expect(
        PremiumPurchase.intentExpiry(
          'upi://mandate?QRexpire=2026-04-14T18:00:00.000%2B00:00',
          launchedAt,
        ),
        launchedAt.add(const Duration(minutes: 15)),
      );
    });
  });

  // ─── Coming back with the order still open ────────────────────────────────

  testWidgets('a return with the order open resumes, it does NOT abandon', (
    tester,
  ) async {
    final api = _FakeApi(const ['pending'], intentUrl: _noExpiryUrl);
    final container = await build(tester, api);
    final launchedAt = tester.binding.clock.now();
    await launchThenReturn(tester, container);

    final state = container.read(premiumPurchaseProvider);
    expect(state, isA<PurchaseResumable>());
    expect(
      api.abandons,
      0,
      reason: 'a mere return must never revoke a live mandate',
    );
    expect(api.initiates, 1);
    expect((state as PurchaseResumable).intentUrl, _noExpiryUrl);
    expect(state.targetApp, _phonePe);
    expect(state.merchantOrderId, 'DKS_ORDER_1');
    // No QRexpire -> the conservative window, shorter than PhonePe's documented maximum.
    expect(
      state.expiresAt.difference(launchedAt),
      lessThanOrEqualTo(const Duration(minutes: 10)),
    );
    expect(
      state.expiresAt.difference(launchedAt),
      greaterThan(const Duration(minutes: 9)),
    );
    expect(eventsNamed('payment_failed'), isEmpty);
    await drain(tester);
  });

  testWidgets('the deadline comes from the link when it carries one', (
    tester,
  ) async {
    final expiry = tester.binding.clock.now().add(const Duration(minutes: 11));
    final api = _FakeApi(const ['pending'], intentUrl: _urlExpiringAt(expiry));
    final container = await build(tester, api);
    await launchThenReturn(tester, container);

    final state = container.read(premiumPurchaseProvider);
    expect(state, isA<PurchaseResumable>());
    expect(
      (state as PurchaseResumable).expiresAt.toUtc(),
      expiry.toUtc(),
      reason: 'QRexpire is the order\'s own deadline, not ours',
    );
    await drain(tester);
  });

  // ─── The resume button ────────────────────────────────────────────────────

  testWidgets('resuming re-fires the SAME link, with no new order and no ★', (
    tester,
  ) async {
    final api = _FakeApi(const ['pending'], intentUrl: _noExpiryUrl);
    final container = await build(tester, api);
    await launchThenReturn(tester, container);
    final first = container.read(premiumPurchaseProvider) as PurchaseResumable;
    expect(launches, hasLength(1));

    final notifier = container.read(premiumPurchaseProvider.notifier);
    unawaited(notifier.resumeIntent());
    await tester.pump(const Duration(milliseconds: 10));

    expect(launches, hasLength(2));
    expect(launches.last['url'], _noExpiryUrl);
    expect(launches.last['package'], _phonePe);
    expect(
      api.initiates,
      1,
      reason: 'a second initiate revokes the live order',
    );
    expect(
      eventsNamed('checkout_started'),
      hasLength(1),
      reason: 'one checkout per decision — a resume is the same decision',
    );
    expect(container.read(premiumPurchaseProvider), isA<PurchaseProcessing>());

    // A second tap while the app is already opening joins the flow; it never launches twice.
    unawaited(notifier.resumeIntent());
    await tester.pump(const Duration(milliseconds: 10));
    expect(launches, hasLength(2));

    // Back again, still unapproved -> resumable once more, on the SAME deadline. Never extended,
    // or a user tapping every minute would hold an order open past the life PhonePe gave it.
    unawaited(notifier.pollNowOnResume());
    await tester.pump(const Duration(milliseconds: 200));
    final second = container.read(premiumPurchaseProvider);
    expect(second, isA<PurchaseResumable>());
    expect((second as PurchaseResumable).expiresAt, first.expiresAt);
    expect(api.abandons, 0);
    await drain(tester);
  });

  testWidgets('a launch that fails abandons and says so', (tester) async {
    final api = _FakeApi(const ['pending'], intentUrl: _noExpiryUrl);
    final container = await build(tester, api);
    await launchThenReturn(tester, container);

    launchSucceeds = false;
    await container.read(premiumPurchaseProvider.notifier).resumeIntent();
    await tester.pump(const Duration(milliseconds: 10));

    expect(container.read(premiumPurchaseProvider), isA<PurchaseError>());
    expect(api.abandons, 1);
    expect(
      eventsNamed('payment_failed').single?['reason'],
      'upi_launch_failed',
    );
    await drain(tester);
  });

  // ─── The deadline retires the order by itself ─────────────────────────────
  // There is no "Start over" button any more: this audience is not payment-literate, so the app
  // decides and keeps the screen automatic (owner's call). The ONE thing that ends a resumable
  // attempt is its own deadline, and it ends it SILENTLY.

  testWidgets('the deadline releases the claim and a fresh tap gets a new order', (
    tester,
  ) async {
    final api = _FakeApi(const ['pending'], intentUrl: _noExpiryUrl);
    final container = await build(tester, api);
    // Every state the screen would have toasted on — a failure line here would be false: the
    // person never approved anything, so nothing failed and nothing was deducted.
    final seen = <PurchaseState>[];
    final watch = container.listen(premiumPurchaseProvider, (_, next) {
      seen.add(next);
    });
    addTearDown(watch.close);
    await launchThenReturn(tester, container);
    expect(container.read(premiumPurchaseProvider), isA<PurchaseResumable>());

    // Past the 10-minute fallback window — nobody tapped anything, the clock did this.
    await tester.pump(const Duration(minutes: 11));

    expect(api.abandons, 1);
    expect(container.read(premiumPurchaseProvider), isA<PurchaseIdle>());
    expect(
      seen.whereType<PurchaseError>(),
      isEmpty,
      reason: 'the window closing is not a payment failure the user can see',
    );
    expect(
      prefs.getKeys(),
      isNotEmpty,
      reason: 'the dead setup still arms the nudge',
    );
    expect(eventsNamed('payment_failed'), [
      {
        'reason': 'intent_resume_expired',
        'cancelled': false,
        'plan': 'monthly',
        'method': 'upi_app',
      },
    ]);

    // The claim is gone -> the CTA reads as the offer again and works, on a genuinely new order.
    unawaited(
      container
          .read(premiumPurchaseProvider.notifier)
          .startTrial(targetApp: _phonePe, trialEligible: true),
    );
    await tester.pump(const Duration(milliseconds: 10));
    expect(api.initiates, 2);
    expect(eventsNamed('checkout_started'), hasLength(2));
    await drain(tester);
  });

  testWidgets('a server expired verdict while resumable is silent too', (
    tester,
  ) async {
    // The watch's first tick finds the order dead at PhonePe. Same reasoning as the deadline: the
    // sheet was reached and left, so "any amount deducted will be refunded" is false information.
    final api = _FakeApi(const ['pending', 'expired'], intentUrl: _noExpiryUrl);
    final container = await build(tester, api);
    final seen = <PurchaseState>[];
    final watch = container.listen(premiumPurchaseProvider, (_, next) {
      seen.add(next);
    });
    addTearDown(watch.close);
    await launchThenReturn(tester, container);
    expect(container.read(premiumPurchaseProvider), isA<PurchaseResumable>());

    await tester.pump(const Duration(seconds: 5));

    expect(container.read(premiumPurchaseProvider), isA<PurchaseIdle>());
    expect(seen.whereType<PurchaseError>(), isEmpty);
    expect(eventsNamed('payment_failed').single?['reason'], 'expired');
    expect(prefs.getKeys(), isNotEmpty);
    expect(api.abandons, 0, reason: 'the server already owns this outcome');
    await drain(tester);
  });

  // ─── The approval that lands anyway ───────────────────────────────────────

  testWidgets('an approval during the wait settles by itself, unresumed', (
    tester,
  ) async {
    final api = _FakeApi(const [
      'pending',
      'trialing',
    ], intentUrl: _noExpiryUrl);
    final container = await build(tester, api);
    await launchThenReturn(tester, container);
    expect(container.read(premiumPurchaseProvider), isA<PurchaseResumable>());

    // The slow watch's first tick.
    await tester.pump(const Duration(seconds: 5));

    expect(container.read(premiumPurchaseProvider), isA<PurchaseSuccess>());
    expect(eventsNamed('trial_started'), [
      {
        'plan': 'monthly',
        'order_id': 'DKS_ORDER_1',
        'value': 199.0,
        'method': 'upi_app',
        'target_app': _phonePe,
      },
    ]);
    expect(api.abandons, 0);
    await drain(tester);
  });

  testWidgets('an approval AFTER a resume is marked as a resumed conversion', (
    tester,
  ) async {
    final api = _FakeApi(const [
      'pending',
      'trialing',
    ], intentUrl: _noExpiryUrl);
    final container = await build(tester, api);
    await launchThenReturn(tester, container);

    unawaited(container.read(premiumPurchaseProvider.notifier).resumeIntent());
    await tester.pump(const Duration(seconds: 10));

    expect(container.read(premiumPurchaseProvider), isA<PurchaseSuccess>());
    expect(
      eventsNamed('trial_started').single?['method'],
      'upi_app_resumed',
      reason: 'the only marker that the resume button earned this trial',
    );
    expect(
      eventsNamed('checkout_started').single?['method'],
      'upi_app',
      reason: 'the tap that started the checkout is untouched by the resume',
    );
    await drain(tester);
  });

  // ─── The deadline running out ─────────────────────────────────────────────

  testWidgets('the window closing abandons exactly once, quietly', (
    tester,
  ) async {
    final api = _FakeApi(const ['pending'], intentUrl: _noExpiryUrl);
    final container = await build(tester, api);
    await launchThenReturn(tester, container);
    expect(container.read(premiumPurchaseProvider), isA<PurchaseResumable>());

    // Past the 10-minute fallback window — the mandate link is dead at PhonePe by now.
    await tester.pump(const Duration(minutes: 11));

    expect(api.abandons, 1);
    // Idle, never PurchaseError: nothing was approved, so nothing failed to say so about.
    expect(container.read(premiumPurchaseProvider), isA<PurchaseIdle>());
    expect(
      eventsNamed('payment_failed').single?['reason'],
      'intent_resume_expired',
    );
    // The nudge is remembered exactly as any other dead setup.
    expect(prefs.getKeys(), isNotEmpty);
    await drain(tester);
  });

  // ─── The handoff is remembered, not only the ending ───────────────────────
  // Half of the people who tap the CTA never reach a terminal path: the process dies behind the UPI
  // app, or they come back and walk off the paywall with the order still open, which disposes the
  // notifier and ends its watch without an event. The marker is therefore written AT the handoff,
  // so the feed row and the reminder reach them too, and every settled outcome forgets it.

  testWidgets('the handoff writes the marker before any outcome exists', (
    tester,
  ) async {
    final api = _FakeApi(const ['pending'], intentUrl: _noExpiryUrl);
    final container = await build(tester, api);
    unawaited(
      container
          .read(premiumPurchaseProvider.notifier)
          .startTrial(targetApp: _phonePe, trialEligible: true),
    );
    await tester.pump(const Duration(milliseconds: 10));

    expect(launches, hasLength(1));
    expect(prefs.getString(TrialNudge.orderKey), 'DKS_ORDER_1');
    expect(TrialNudge.isLive(prefs, DateTime.now()), isTrue);
    expect(eventsNamed('payment_failed'), isEmpty);
    await drain(tester);
  });

  testWidgets('walking off the paywall with the order open keeps the marker', (
    tester,
  ) async {
    final api = _FakeApi(const ['pending'], intentUrl: _noExpiryUrl);
    final container = await build(tester, api);
    await launchThenReturn(tester, container);
    expect(container.read(premiumPurchaseProvider), isA<PurchaseResumable>());

    // The paywall is popped: the autoDispose notifier goes with it and its watch ends silently —
    // no abandon, no `payment_failed`. This is the walk-away nothing used to remember.
    container.invalidate(premiumPurchaseProvider);
    await tester.pump(const Duration(minutes: 20));

    expect(eventsNamed('payment_failed'), isEmpty);
    expect(TrialNudge.isLive(prefs, DateTime.now()), isTrue);
    expect(prefs.getString(TrialNudge.orderKey), 'DKS_ORDER_1');
  });

  testWidgets('an approval forgets the handoff marker', (tester) async {
    final api = _FakeApi(const ['trialing'], intentUrl: _noExpiryUrl);
    final container = await build(tester, api);
    unawaited(
      container
          .read(premiumPurchaseProvider.notifier)
          .startTrial(targetApp: _phonePe, trialEligible: true),
    );
    await tester.pump(const Duration(milliseconds: 10));
    // Written first — or "it is null afterwards" would hold with no marker ever existing.
    expect(prefs.getString(TrialNudge.orderKey), 'DKS_ORDER_1');

    unawaited(
      container.read(premiumPurchaseProvider.notifier).pollNowOnResume(),
    );
    await tester.pump(const Duration(milliseconds: 200));

    expect(container.read(premiumPurchaseProvider), isA<PurchaseSuccess>());
    expect(prefs.getInt(TrialNudge.markerKey), isNull);
    expect(prefs.getString(TrialNudge.orderKey), isNull);
    await drain(tester);
  });

  testWidgets('a spent-trial checkout never writes the marker', (tester) async {
    // The row and the reminder both say "free trial" — a lie to someone abandoning a ₹199 charge.
    final api = _FakeApi(const ['pending'], intentUrl: _noExpiryUrl);
    final container = await build(tester, api);
    unawaited(
      container
          .read(premiumPurchaseProvider.notifier)
          .startTrial(targetApp: _phonePe, trialEligible: false),
    );
    await tester.pump(const Duration(milliseconds: 10));

    expect(launches, hasLength(1));
    expect(prefs.getInt(TrialNudge.markerKey), isNull);
    await drain(tester);
  });

  // ─── Changing the app while the order is open ─────────────────────────────
  // "If PhonePe is there, only show PhonePe" is not a choice. The picker stays live, and picking
  // another app is one motion: this order dies exactly as the deadline kills it, and a fresh order
  // opens in the app they just chose. What they must NEVER see in between is a failure.

  testWidgets('switching apps abandons the open order and initiates a new one', (
    tester,
  ) async {
    final api = _FakeApi(const ['pending'], intentUrl: _noExpiryUrl);
    final container = await build(tester, api);
    await launchThenReturn(tester, container);
    expect(container.read(premiumPurchaseProvider), isA<PurchaseResumable>());

    // Every state the screen would have toasted on — the flash this feature must not have.
    final seen = <PurchaseState>[];
    final watch = container.listen(premiumPurchaseProvider, (_, next) {
      seen.add(next);
    });
    addTearDown(watch.close);

    unawaited(
      container
          .read(premiumPurchaseProvider.notifier)
          .switchApp(_gpay, trialEligible: true),
    );
    await tester.pump(const Duration(milliseconds: 10));

    expect(api.abandons, 1, reason: 'the order it replaces has to be released');
    expect(api.initiates, 2);
    expect(launches, hasLength(2));
    expect(launches.last['package'], _gpay);
    expect(container.read(premiumPurchaseProvider), isA<PurchaseProcessing>());

    // A new decision -> a second checkout, carrying the app that earned it.
    final started = eventsNamed('checkout_started');
    expect(started, hasLength(2));
    expect(started.last?['method'], 'upi_app');
    expect(started.last?['target_app'], _gpay);
    // The abandon still counts, under its own reason.
    expect(
      eventsNamed('payment_failed').single?['reason'],
      'intent_app_switched',
    );
    expect(
      seen.whereType<PurchaseError>(),
      isEmpty,
      reason:
          'the person tapped an app — a failure toast may never flash first',
    );
    await drain(tester);
  });

  testWidgets('picking the app that already holds the order does nothing', (
    tester,
  ) async {
    final api = _FakeApi(const ['pending'], intentUrl: _noExpiryUrl);
    final container = await build(tester, api);
    await launchThenReturn(tester, container);
    final before = container.read(premiumPurchaseProvider) as PurchaseResumable;

    await container
        .read(premiumPurchaseProvider.notifier)
        .switchApp(_phonePe, trialEligible: true);
    await tester.pump(const Duration(milliseconds: 10));

    expect(api.abandons, 0);
    expect(api.initiates, 1);
    expect(launches, hasLength(1));
    expect(eventsNamed('checkout_started'), hasLength(1));
    expect(eventsNamed('payment_failed'), isEmpty);
    final after = container.read(premiumPurchaseProvider);
    expect(after, isA<PurchaseResumable>());
    expect((after as PurchaseResumable).expiresAt, before.expiresAt);
    await drain(tester);
  });

  // The picker's QR row reaches `switchApp` naming `com.phonepe.app`, because PhonePe makes
  // `targetApp` mandatory on UPI_INTENT and the QR has to name something. Over an order already
  // open at PhonePe that is the SAME package, so the guard above would have read a real change of
  // route as "picking the app that already holds the order" and done nothing at all — a dead row in
  // the sheet for the rest of the window.
  testWidgets('picking QR over an order open at that very app still switches '
      'route — the same-app guard must not swallow it', (tester) async {
    final api = _FakeApi(const ['pending'], intentUrl: _noExpiryUrl);
    final container = await build(tester, api);
    await launchThenReturn(tester, container);

    unawaited(
      container
          .read(premiumPurchaseProvider.notifier)
          .switchApp(_phonePe, trialEligible: true, asQr: true),
    );
    await tester.pump(const Duration(milliseconds: 10));

    expect(
      api.abandons,
      1,
      reason: 'two live mandates is what the server refuses',
    );
    expect(api.initiates, 2);
    // Nothing is LAUNCHED on the QR route: the code is for another phone to scan.
    expect(launches, hasLength(1), reason: 'the first launch only');
    expect(container.read(premiumPurchaseProvider), isA<PurchaseScannable>());

    // Filed under its own method, never `upi_app` with the formality package — that column answers
    // "which app completes a mandate" and this phone launched nothing.
    final started = eventsNamed('checkout_started');
    expect(started, hasLength(2));
    expect(started.last?['method'], 'upi_qr');
    expect(started.last?['target_app'], isNull);
    await drain(tester);
  });

  // ─── The CTA is not a second door ─────────────────────────────────────────

  testWidgets('startTrial does nothing while an attempt is resumable', (
    tester,
  ) async {
    final api = _FakeApi(const ['pending'], intentUrl: _noExpiryUrl);
    final container = await build(tester, api);
    await launchThenReturn(tester, container);

    await container
        .read(premiumPurchaseProvider.notifier)
        .startTrial(targetApp: _phonePe, trialEligible: true);
    await tester.pump(const Duration(milliseconds: 10));

    expect(api.initiates, 1);
    expect(launches, hasLength(1));
    expect(eventsNamed('checkout_started'), hasLength(1));
    expect(container.read(premiumPurchaseProvider), isA<PurchaseResumable>());
    await drain(tester);
  });

  // ─── The return page's taps are tagged ────────────────────────────────────

  group('surface', () {
    testWidgets('a checkout from the return page says so, start to trial', (
      tester,
    ) async {
      final api = _FakeApi(const ['trialing'], intentUrl: _noExpiryUrl);
      final container = await build(tester, api);
      unawaited(
        container
            .read(premiumPurchaseProvider.notifier)
            .startTrial(
              targetApp: _phonePe,
              trialEligible: true,
              surface: 'return',
            ),
      );
      await tester.pump(const Duration(seconds: 5));
      expect(eventsNamed('checkout_started').single?['surface'], 'return');
      expect(eventsNamed('trial_started').single?['surface'], 'return');
      await drain(tester);
    });

    testWidgets("the trial screen's own checkout carries no surface", (
      tester,
    ) async {
      final api = _FakeApi(const ['trialing'], intentUrl: _noExpiryUrl);
      final container = await build(tester, api);
      unawaited(
        container
            .read(premiumPurchaseProvider.notifier)
            .startTrial(targetApp: _phonePe, trialEligible: true),
      );
      await tester.pump(const Duration(seconds: 5));
      expect(
        eventsNamed('checkout_started').single?.containsKey('surface'),
        isFalse,
      );
      expect(
        eventsNamed('trial_started').single?.containsKey('surface'),
        isFalse,
      );
      await drain(tester);
    });

    testWidgets('a resume from the return page tags the trial it wins', (
      tester,
    ) async {
      final api = _FakeApi(const [
        'pending',
        'trialing',
      ], intentUrl: _noExpiryUrl);
      final container = await build(tester, api);
      await launchThenReturn(tester, container);
      expect(container.read(premiumPurchaseProvider), isA<PurchaseResumable>());

      unawaited(
        container
            .read(premiumPurchaseProvider.notifier)
            .resumeIntent(surface: 'return'),
      );
      await tester.pump(const Duration(seconds: 5));
      final trial = eventsNamed('trial_started').single;
      expect(trial?['surface'], 'return');
      expect(trial?['method'], 'upi_app_resumed');
      // Still ONE checkout per decision — the resume is not a second one.
      expect(eventsNamed('checkout_started'), hasLength(1));
      await drain(tester);
    });

    testWidgets('a switch from the return page tags the fresh checkout', (
      tester,
    ) async {
      final api = _FakeApi(const ['pending'], intentUrl: _noExpiryUrl);
      final container = await build(tester, api);
      await launchThenReturn(tester, container);
      unawaited(
        container
            .read(premiumPurchaseProvider.notifier)
            .switchApp(_gpay, trialEligible: true, surface: 'return'),
      );
      await tester.pump(const Duration(milliseconds: 50));
      final checkouts = eventsNamed('checkout_started');
      expect(checkouts, hasLength(2));
      expect(checkouts.first?.containsKey('surface'), isFalse);
      expect(checkouts.last?['surface'], 'return');
      await drain(tester);
    });
  });
}
