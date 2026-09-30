// JourneyStamps puts install-lifetime counters and phone facts onto events that already fire, so the
// PostHog event count never grows. What is pinned: the counters survive a relaunch, an unstarted
// process reports nothing rather than a false zero, a sign-in attempt carries the history BEFORE
// it, and a failed native read stays absent — a missing value must never read as "offline".
import 'package:arul/core/analytics/analytics_service.dart';
import 'package:arul/core/analytics/google_analytics_service.dart';
import 'package:arul/core/analytics/journey_stamps.dart';
import 'package:arul/core/config/build_info.dart';
import 'package:arul/core/upi/upi_apps.dart';
import 'package:arul/features/auth/data/api_auth_service.dart';
import 'package:arul/features/referral/data/install_referrer_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const buildInfo = MethodChannel('com.hsrutility.arul/build_info');
  const upi = MethodChannel('com.hsrutility.arul/upi_intent');

  setUp(JourneyStamps.debugReset);
  tearDown(() {
    messenger
      ..setMockMethodCallHandler(buildInfo, null)
      ..setMockMethodCallHandler(upi, null);
  });

  Future<SharedPreferences> started({DateTime? now}) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    JourneyStamps.start(prefs, now: now);
    return prefs;
  }

  test('the /geo stamps are absent until asked, then carry the outcome', () {
    expect(JourneyStamps.geoProps, isEmpty);

    JourneyStamps.noteGeo('pending');
    expect(JourneyStamps.geoProps, {'geo_outcome': 'pending'});

    JourneyStamps.noteGeo('answered', ms: 640);
    JourneyStamps.noteRegionWait('settled');
    expect(JourneyStamps.geoProps, {
      'geo_outcome': 'answered',
      'geo_ms': 640,
      'region_wait': 'settled',
    });

    JourneyStamps.debugReset();
    expect(JourneyStamps.geoProps, isEmpty);
  });

  test('the /geo stamps never reach GA4', () {
    for (final key in ['geo_outcome', 'geo_ms', 'region_wait', 'warm_ms']) {
      expect(kPostHogOnlyProperties, contains(key));
    }
  });

  test(
    'launches count up across processes and age is days since the first',
    () async {
      final day0 = DateTime(2026, 9, 1, 10);
      final prefs = await started(now: day0);
      expect(JourneyStamps.launchProps, containsPair('launch_n', 1));
      expect(JourneyStamps.launchProps, containsPair('install_age_d', 0));
      expect(JourneyStamps.launchProps['text_scale'], isA<num>());
      expect(JourneyStamps.launchProps['sys_dark'], isA<bool>());

      JourneyStamps.start(
        prefs,
        now: day0.add(const Duration(days: 3, hours: 2)),
      );
      expect(JourneyStamps.launchProps, containsPair('launch_n', 2));
      expect(JourneyStamps.launchProps, containsPair('install_age_d', 3));
    },
  );

  test('a sign-in attempt carries the history BEFORE it', () async {
    final t0 = DateTime(2026, 9, 1, 10);
    await started(now: t0);

    final first = JourneyStamps.signInHistory(now: t0);
    expect(first.containsKey('prev_outcome'), isFalse);
    expect(first['cancels_n'], 0);
    expect(JourneyStamps.nextAttempt(now: t0), 1);

    JourneyStamps.noteSignInOutcome(
      'cancelled:backedOutQuick',
      now: t0.add(const Duration(seconds: 4)),
    );
    final second = JourneyStamps.signInHistory(
      now: t0.add(const Duration(seconds: 34)),
    );
    expect(second['prev_outcome'], 'cancelled:backedOutQuick');
    expect(second['s_since_prev_outcome'], 30);
    expect(second['left_since_prev'], isFalse);
    expect(second['cancels_n'], 1);
    expect(second['fails_n'], 0);
    expect(second['s_since_first_attempt'], 34);
    expect(second['s_since_install'], 34);

    JourneyStamps.noteSignInOutcome('failed:networkError');
    expect(JourneyStamps.signInHistory()['fails_n'], 1);
  });

  test('an outcome from an earlier process means the person left', () async {
    final prefs = await started();
    JourneyStamps.noteSignInOutcome('cancelled:backedOutQuick');
    JourneyStamps.debugReset();
    JourneyStamps.start(prefs);
    expect(JourneyStamps.signInHistory()['left_since_prev'], isTrue);
  });

  test(
    'the path to a trial reads back, the gate and browse depth included',
    () async {
      await started();
      JourneyStamps.notePaywallView(
        'apply',
        now: DateTime.now().subtract(const Duration(seconds: 50)),
      );
      JourneyStamps.noteGate('share', category: 'murugan', itemId: 'w-1');
      JourneyStamps.noteCardEngaged();
      JourneyStamps.noteCardEngaged();
      JourneyStamps.noteRingtonePreview();
      JourneyStamps.markLogin(
        now: DateTime.now().subtract(const Duration(seconds: 90)),
      );
      expect(
        JourneyStamps.nextCheckout(
          now: DateTime.now().subtract(const Duration(seconds: 20)),
        ),
        1,
      );

      final props = JourneyStamps.conversionProps();
      expect(props['checkout_n'], 1);
      expect(props['paywall_n'], 1);
      expect(props['paywall_source'], 'apply');
      expect(props['gate_kind'], 'share');
      expect(props['gate_category'], 'murugan');
      expect(props['gate_item'], 'w-1');
      expect(props['cards_n'], 2);
      expect(props['previews_n'], 1);
      expect(props['s_since_login'], inInclusiveRange(89, 95));
      expect(props['s_on_paywall'], inInclusiveRange(29, 31));
      expect(props['s_tap_to_trial'], inInclusiveRange(19, 25));

      JourneyStamps.noteGate('ringtone_set');
      expect(JourneyStamps.conversionProps().containsKey('gate_item'), isFalse);

      final context = JourneyStamps.checkoutContext()!;
      expect(context.containsKey('s_tap_to_trial'), isFalse);
      expect(context['launch_n'], 1);
    },
  );

  test('an unstarted process reports no counts and no context at all', () {
    expect(JourneyStamps.nextAttempt(), isNull);
    expect(JourneyStamps.nextCheckout(), isNull);
    expect(JourneyStamps.conversionProps(), isEmpty);
    expect(JourneyStamps.signInHistory(), isEmpty);
    expect(JourneyStamps.checkoutContext(), isNull);
    expect(JourneyStamps.secondsSinceLogin(), isNull);
  });

  test('device facts: every native reading mapped, the UPI mix joined', () async {
    messenger
      ..setMockMethodCallHandler(buildInfo, (call) async {
        if (call.method == 'dataSaverOn') return true;
        expect(call.method, 'analyticsFacts');
        return {
          'thermal': 1,
          'launchSource': 'push',
          'procAgeMs': 5000000,
          'gmsVersion': 253832035,
          'gmsStatus': 0,
          'playStoreVersion': 84251800,
          'powerSaver': true,
          'bootAgeMin': 12,
          'availMemMb': 812,
          'lowMemNow': false,
          'freeStorageMb': 2048,
          'batteryPct': 41,
          'charging': false,
          'abi': 'arm64-v8a',
          'unknownKey': 1,
          'batteryPctNull': null,
        };
      })
      ..setMockMethodCallHandler(upi, (call) async {
        expect(call.method, 'listUpiPackages');
        return ['com.phonepe.app', 'com.google.android.apps.nbu.paisa.user'];
      });

    final prefs = await started();
    final landed = JourneyStamps.onDeviceFacts;
    final facts = await JourneyStamps.probeDeviceFacts();
    expect(facts['ms_before_main'], inInclusiveRange(4990000, 5000000));
    expect(facts, {
      'ms_before_main': facts['ms_before_main'],
      'thermal': 1,
      'launch_source': 'push',
      'data_saver': true,
      'gms_version': 253832035,
      'gms_status': 0,
      'play_store_version': 84251800,
      'power_saver': true,
      'boot_age_min': 12,
      'avail_mem_mb': 812,
      'low_mem_now': false,
      'free_storage_mb': 2048,
      'battery_pct': 41,
      'charging': false,
      'abi': 'arm64-v8a',
      'upi_apps': 'gpay,phonepe',
    });
    expect(await landed, same(facts));
    expect(JourneyStamps.deviceFacts, facts);

    // The next launch's first attempt carries only what a phone keeps between launches.
    JourneyStamps.debugReset();
    JourneyStamps.start(prefs);
    expect(JourneyStamps.lastDeviceFacts, {
      'gms_version': 253832035,
      'gms_status': 0,
      'play_store_version': 84251800,
      'abi': 'arm64-v8a',
      'upi_apps': 'gpay,phonepe',
    });
  });

  test(
    'render props: slow frames, the worst frame and the wall clip',
    () async {
      await started();
      expect(JourneyStamps.renderProps, {
        'slow_frames': 0,
        'worst_frame_ms': 0,
        'wall_clip': 'unknown',
      });
      JourneyStamps.noteWallClip('playing');
      expect(JourneyStamps.renderProps['wall_clip'], 'playing');
    },
  );

  test('wall_clip is never absent: it names why there is no clip yet', () async {
    addTearDown(DeviceQuality.resetForTesting);
    await started();
    String clip() => JourneyStamps.renderProps['wall_clip']! as String;

    DeviceQuality.debugSetTier(DeviceTier.mid);
    JourneyStamps.noteClipArm(active: false);
    expect(clip(), 'not_in_arm');
    JourneyStamps.noteClipArm(active: true);
    expect(clip(), 'not_started');

    // The poster rule outranks the arm: neither arm plays anything on these phones.
    DeviceQuality.debugSetTier(DeviceTier.low);
    expect(clip(), 'poster');
    JourneyStamps.noteClipArm(active: false);
    expect(clip(), 'poster');

    // Once the clip path speaks, its value wins, unchanged.
    JourneyStamps.noteWallClip('downloading');
    expect(clip(), 'downloading');
  });

  test('back-to-back attempts never share an attempt_n', () async {
    final prefs = await started();
    expect(
      [
        JourneyStamps.nextAttempt(),
        JourneyStamps.nextAttempt(),
        JourneyStamps.nextAttempt(),
      ],
      [1, 2, 3],
    );
    // The count reaches the store without waiting on the disk write.
    expect(prefs.getInt('journey_signin_attempts'), 3);
  });

  test('the picker and the default app ride the path to a trial', () async {
    await started();
    JourneyStamps.noteDefaultApp('phonepe');
    JourneyStamps.notePickerOpened();
    JourneyStamps.notePickerOpened();
    JourneyStamps.notePickedApp('gpay');
    final props = JourneyStamps.conversionProps();
    expect(props['default_app'], 'phonepe');
    expect(props['picker_opens'], 2);
    expect(props['picked_app'], 'gpay');
  });

  test(
    'a paywall exit reads cta after a tap, back otherwise, with the dwell',
    () async {
      await started();
      expect(JourneyStamps.paywallExit(), isNull);
      final opened = DateTime.now().subtract(const Duration(seconds: 30));
      JourneyStamps.notePaywallView('apply', now: opened);
      expect(JourneyStamps.paywallExit(), {'exit': 'back', 'dwell_s': 30});
      JourneyStamps.nextCheckout(now: opened.add(const Duration(seconds: 10)));
      expect(JourneyStamps.paywallExit()?['exit'], 'cta');
      expect(JourneyStamps.secondsSinceCheckout(), inInclusiveRange(19, 21));
    },
  );

  test(
    'failed device probes leave the columns absent, never guessed',
    () async {
      messenger
        ..setMockMethodCallHandler(
          buildInfo,
          (_) async => throw PlatformException(code: 'x'),
        )
        ..setMockMethodCallHandler(
          upi,
          (_) async => throw PlatformException(code: 'x'),
        );

      expect(await JourneyStamps.probeDeviceFacts(), isEmpty);
    },
  );

  test(
    'network: the link when connected, zero when not, absent when unknown',
    () async {
      Object? reply;
      messenger.setMockMethodCallHandler(buildInfo, (_) async => reply);

      reply = {
        'connected': true,
        'downKbps': 3200,
        'upKbps': 900,
        'validated': true,
        'vpn': false,
        'metered': true,
      };
      await JourneyStamps.probeNetwork();
      expect(JourneyStamps.networkFacts, {
        'net_kbps': 3200,
        'net_validated': true,
        'net_up_kbps': 900,
        'net_vpn': false,
        'net_metered': true,
      });

      reply = {'connected': false};
      await JourneyStamps.probeNetwork();
      expect(JourneyStamps.networkFacts, {
        'net_kbps': 0,
        'net_validated': false,
      });

      reply = <String, Object?>{};
      await JourneyStamps.probeNetwork();
      expect(JourneyStamps.networkFacts, isEmpty);

      JourneyStamps.debugSetFacts(network: {'net_kbps': 1});
      JourneyStamps.forgetNetwork();
      expect(JourneyStamps.networkFacts, isEmpty);
    },
  );

  test(
    'UPI codes are sorted into one value per app mix, none for an empty set',
    () {
      expect(
        UpiApps.analyticsCodes(['net.one97.paytm', 'com.phonepe.app']),
        'paytm,phonepe',
      );
      expect(UpiApps.analyticsCodes(const []), 'none');
    },
  );

  test("the Worker's login analytics pass through as scalars only", () {
    expect(
      ApiAuthService.loginAnalytics({
        'new_user': false,
        'sub_status': 'expired',
        'trial_used': true,
        'account_age_d': 12,
        'internal': false,
        'nested': {'x': 1},
        'nothing': null,
        'long': 'x' * 150,
      }),
      {
        'new_user': false,
        'sub_status': 'expired',
        'trial_used': true,
        'account_age_d': 12,
        'internal': false,
        'long': 'x' * 100,
      },
    );
    expect(ApiAuthService.loginAnalytics(null), isEmpty);
    expect(ApiAuthService.loginAnalytics('nope'), isEmpty);
  });

  test("Play's install clocks ride the attribution once stored", () async {
    SharedPreferences.setMockInitialValues({
      'install_channel': 'google_ads',
      'click_to_install_s': 42,
      'install_to_open_s': 7,
    });
    final prefs = await SharedPreferences.getInstance();
    expect(InstallReferrerService(prefs).attributionProps, {
      'install_channel': 'google_ads',
      'click_to_install_s': 42,
      'install_to_open_s': 7,
    });
  });

  test('GA4 never receives the PostHog-only diagnostics as parameters', () {
    expect(
      GoogleAnalyticsService.parametersFor({
        'attempt_n': 2,
        'net_kbps': 900,
        'provider': 'google',
        'low_ram': true,
        'upi_apps': 'phonepe',
      }),
      {'provider': 'google', 'low_ram': 1, 'upi_apps': 'phonepe'},
    );
    for (final kept in [
      'upi_apps',
      'paywall_source',
      'low_ram',
      'device_tier',
    ]) {
      expect(kPostHogOnlyProperties, isNot(contains(kept)));
    }
  });
}
