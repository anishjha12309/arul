import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/build_info.dart';
import '../connectivity/data_saver.dart';
import '../upi/upi_apps.dart';

/// Install-lifetime counters, the process clock and a few phone facts, stamped onto events that
/// already fire -> more signal per event, never another capture (the owner fixes the PostHog event
/// count). Static because `main()` starts it before Riverpod exists and a property is read at capture.
abstract final class JourneyStamps {
  static const _kLaunches = 'journey_launch_count';
  static const _kFirstLaunchMs = 'journey_first_launch_ms';
  static const _kAttempts = 'journey_signin_attempts';
  static const _kFirstAttemptMs = 'journey_first_attempt_ms';
  static const _kCancels = 'journey_signin_cancels';
  static const _kFails = 'journey_signin_fails';
  static const _kPrevOutcome = 'journey_signin_prev_outcome';
  static const _kPrevOutcomeMs = 'journey_signin_prev_outcome_ms';
  static const _kCheckouts = 'journey_checkouts';
  static const _kCheckoutMs = 'journey_checkout_ms';
  static const _kPaywallViews = 'journey_paywall_views';
  static const _kPaywallSource = 'journey_paywall_source';
  static const _kPaywallMs = 'journey_paywall_ms';
  static const _kLoginMs = 'journey_login_ms';
  static const _kGateKind = 'journey_gate_kind';
  static const _kGateCategory = 'journey_gate_category';
  static const _kGateItem = 'journey_gate_item';
  static const _kCards = 'journey_cards_engaged';
  static const _kPreviews = 'journey_ringtone_previews';
  static const _kLastFacts = 'journey_last_device_facts';

  static const _buildInfo = MethodChannel('com.hsrutility.arul/build_info');

  static SharedPreferences? _prefs;
  static final _clock = Stopwatch();
  static var _launchN = 0;
  static var _installAgeD = 0;
  static var _pausedN = 0;
  static var _resumedAtMs = 0;

  /// This process's pause count when its latest sign-in outcome landed; null = that outcome came
  /// from an earlier process, which means the person already left once.
  static int? _pausedAtOutcome;
  static AppLifecycleListener? _lifecycle;

  /// Counts this launch and starts the process clock. Called once from `main()` with prefs in hand;
  /// the counter writes are fire-and-forget because SharedPreferences updates its cache in place.
  static void start(SharedPreferences prefs, {DateTime? now}) {
    _prefs = prefs;
    _clock
      ..reset()
      ..start();
    final nowMs = _ms(now);
    _launchN = (prefs.getInt(_kLaunches) ?? 0) + 1;
    unawaited(prefs.setInt(_kLaunches, _launchN));
    final firstMs = prefs.getInt(_kFirstLaunchMs);
    if (firstMs == null) unawaited(prefs.setInt(_kFirstLaunchMs, nowMs));
    _installAgeD = firstMs == null
        ? 0
        : Duration(milliseconds: nowMs - firstMs).inDays;
    _lifecycle ??= AppLifecycleListener(
      onPause: () => _pausedN++,
      onResume: () => _resumedAtMs = _clock.elapsedMilliseconds,
    );
    if (!_timingsHooked) {
      SchedulerBinding.instance.addTimingsCallback(_onTimings);
      _timingsHooked = true;
    }
  }

  /// How the app rendered up to the event: frames over two vsyncs, the worst frame, and the state of
  /// the wall's launch clip — perf on old phones is the one lever that ever moved sign-in.
  static Map<String, Object> get renderProps => {
    'slow_frames': _slowFrames,
    'worst_frame_ms': _worstFrameMs,
    'wall_clip': _wallClipNow,
  };

  static var _timingsHooked = false;
  static var _slowFrames = 0;
  static var _worstFrameMs = 0;
  static String? _wallClip;
  static bool? _clipArm;

  /// Never absent: before the clip path says anything, the reason there is no clip yet — the poster
  /// rule (either arm), the control arm's lotus, or the regional clip not started.
  static String get _wallClipNow =>
      _wallClip ??
      switch ((DeviceMemory.resolved, _clipArm)) {
        (true, _) => 'poster',
        (_, false) => 'not_in_arm',
        (false, true) => 'not_started',
        _ => 'unknown',
      };

  static void _onTimings(List<FrameTiming> timings) {
    for (final t in timings) {
      final ms = t.totalSpan.inMilliseconds;
      if (ms > 33) _slowFrames++;
      _worstFrameMs = math.max(_worstFrameMs, ms);
    }
  }

  /// What the wall showed behind Google's sheet: `downloading`, `on_disk`, `failed`, `playing`, or why
  /// the regional clip stopped (`slow_link`, `poster`, `no_cdn`, `no_clip`, `data_saver`, `error`).
  static void noteWallClip(String state) => _wallClip = state;

  /// Whether this install is in the regional arm, the only one with a launch clip.
  static void noteClipArm({required bool active}) => _clipArm = active;

  /// The paywall's UPI picker this process: times opened, the app picked, the app it defaulted to.
  static void notePickerOpened() => _pickerOpens++;
  static void notePickedApp(String code) => _pickedApp = code;
  static void noteDefaultApp(String code) => _defaultApp = code;
  static var _pickerOpens = 0;
  static String? _pickedApp;
  static String? _defaultApp;

  /// Registered on every event of the process: which cold start of this install it is, how many
  /// days since its first, and how the phone renders text — a low-literacy audience runs large fonts.
  static Map<String, Object> get launchProps {
    final dispatcher = PlatformDispatcher.instance;
    return {
      'launch_n': _launchN,
      'install_age_d': _installAgeD,
      'text_scale': (dispatcher.textScaleFactor * 10).round() / 10,
      'sys_dark': dispatcher.platformBrightness == Brightness.dark,
    };
  }

  /// Since `main()` started this process — how long the person had been in the app at the event.
  static int get msSinceLaunch => _clock.elapsedMilliseconds;

  /// This install's sign-in attempt ordinal, counted at `login_attempt`; every event of that
  /// attempt carries the same number, so "which try finally worked" needs no sequence rebuild.
  static int? nextAttempt({DateTime? now}) {
    final n = _bump(_kAttempts);
    if (n == 1) unawaited(_prefs?.setInt(_kFirstAttemptMs, _ms(now)));
    return n;
  }

  /// What the person had been through before THIS attempt, frozen at `login_attempt` and carried by
  /// every event of the attempt: the previous outcome and how long ago, whether they left the app
  /// since, how many sheets they had already dismissed or seen fail, and how long they have had it.
  static Map<String, Object> signInHistory({DateTime? now}) {
    final prefs = _prefs;
    if (prefs == null) return const {};
    final nowMs = _ms(now);
    final prevMs = prefs.getInt(_kPrevOutcomeMs);
    final firstAttemptMs = prefs.getInt(_kFirstAttemptMs);
    final firstLaunchMs = prefs.getInt(_kFirstLaunchMs);
    final pausedAt = _pausedAtOutcome;
    return {
      'prev_outcome': ?prefs.getString(_kPrevOutcome),
      if (prevMs != null) 's_since_prev_outcome': (nowMs - prevMs) ~/ 1000,
      if (prevMs != null)
        'left_since_prev': pausedAt == null || _pausedN > pausedAt,
      'cancels_n': prefs.getInt(_kCancels) ?? 0,
      'fails_n': prefs.getInt(_kFails) ?? 0,
      if (firstAttemptMs != null)
        's_since_first_attempt': (nowMs - firstAttemptMs) ~/ 1000,
      if (firstLaunchMs != null)
        's_since_install': (nowMs - firstLaunchMs) ~/ 1000,
      'app_paused_n': _pausedN,
      'ms_since_resume': _clock.elapsedMilliseconds - _resumedAtMs,
    };
  }

  /// Records how a sign-in attempt ended (`success`, `cancelled:<nudge>`, `failed:<kind>`) for the
  /// next attempt's [signInHistory].
  static void noteSignInOutcome(String outcome, {DateTime? now}) {
    final prefs = _prefs;
    if (prefs == null) return;
    if (outcome.startsWith('cancelled')) _bump(_kCancels);
    if (outcome.startsWith('failed')) _bump(_kFails);
    unawaited(prefs.setString(_kPrevOutcome, outcome));
    unawaited(prefs.setInt(_kPrevOutcomeMs, _ms(now)));
    _pausedAtOutcome = _pausedN;
  }

  /// Checkout taps (`checkout_started`) this install has made, the current one included.
  static int? nextCheckout({DateTime? now}) {
    final n = _bump(_kCheckouts);
    if (n != null) unawaited(_prefs?.setInt(_kCheckoutMs, _ms(now)));
    return n;
  }

  /// Counts a paywall view and keeps which gate opened it (`paywall_source`), for the trial it leads to.
  static void notePaywallView(String source, {DateTime? now}) {
    _paywallPausedAt = _pausedN;
    _bump(_kPaywallViews);
    unawaited(_prefs?.setString(_kPaywallSource, source));
    unawaited(_prefs?.setInt(_kPaywallMs, _ms(now)));
  }

  static int? _paywallPausedAt;

  /// How the latest paywall view ended: `cta` (a checkout was tapped on it), `left_app` (the app went
  /// to the background at least once first), else `back`; and how long it lasted.
  static Map<String, Object>? paywallExit({DateTime? now}) {
    final at = _prefs?.getInt(_kPaywallMs);
    if (at == null) return null;
    final checkoutMs = _prefs?.getInt(_kCheckoutMs);
    final pausedAt = _paywallPausedAt;
    return {
      'exit': checkoutMs != null && checkoutMs >= at
          ? 'cta'
          : (pausedAt != null && _pausedN > pausedAt ? 'left_app' : 'back'),
      'dwell_s': math.max(0, (_ms(now) - at) ~/ 1000),
    };
  }

  /// Since the latest checkout tap — on a failure, roughly the time spent in the UPI app.
  static int? secondsSinceCheckout({DateTime? now}) {
    final at = _prefs?.getInt(_kCheckoutMs);
    return at == null ? null : math.max(0, (_ms(now) - at) ~/ 1000);
  }

  /// The content behind the latest premium gate: `apply`/`share`/`ringtone_set`, its category and id.
  static void noteGate(String kind, {String? category, String? itemId}) {
    final prefs = _prefs;
    if (prefs == null) return;
    unawaited(prefs.setString(_kGateKind, kind));
    unawaited(_setOrRemove(_kGateCategory, category));
    unawaited(_setOrRemove(_kGateItem, itemId));
  }

  /// A wallpaper card the person dwelled on, and a ringtone they previewed — browse depth before a trial.
  static void noteCardEngaged() => _bump(_kCards);
  static void noteRingtonePreview() => _bump(_kPreviews);

  /// The path to a conversion, on `trial_started` — the late catch-up copy included, since every
  /// value is persisted: taps, views, the gate and the content behind it, browse depth, the clocks.
  static Map<String, Object> conversionProps({DateTime? now}) {
    final prefs = _prefs;
    if (prefs == null) return const {};
    final nowMs = _ms(now);
    final paywallMs = prefs.getInt(_kPaywallMs);
    final checkoutMs = prefs.getInt(_kCheckoutMs);
    return {
      'checkout_n': ?prefs.getInt(_kCheckouts),
      'paywall_n': ?prefs.getInt(_kPaywallViews),
      'paywall_source': ?prefs.getString(_kPaywallSource),
      'gate_kind': ?prefs.getString(_kGateKind),
      'gate_category': ?prefs.getString(_kGateCategory),
      'gate_item': ?prefs.getString(_kGateItem),
      'cards_n': prefs.getInt(_kCards) ?? 0,
      'previews_n': prefs.getInt(_kPreviews) ?? 0,
      'default_app': ?_defaultApp,
      if (_pickerOpens > 0) 'picker_opens': _pickerOpens,
      'picked_app': ?_pickedApp,
      's_since_login': ?secondsSinceLogin(now: now),
      if (paywallMs != null && checkoutMs != null && checkoutMs >= paywallMs)
        's_on_paywall': (checkoutMs - paywallMs) ~/ 1000,
      if (checkoutMs != null) 's_tap_to_trial': (nowMs - checkoutMs) ~/ 1000,
    };
  }

  /// What `POST /payments/initiate` stores beside the order -> every tap, approved or not, reaches
  /// PostHog through the Neon warehouse with its path, phone and link. Called AFTER [nextCheckout].
  /// Null before [start], so a test or an unstarted process sends no context at all.
  static Map<String, Object>? checkoutContext({DateTime? now}) => _prefs == null
      ? null
      : {
          ...{...conversionProps(now: now)}..remove('s_tap_to_trial'),
          ...launchProps,
          ..._deviceFacts,
          ..._networkFacts,
        };

  /// The latest sign-in on this install -> `trial_started` carries how long after it the trial came.
  static void markLogin({DateTime? now}) {
    final prefs = _prefs;
    if (prefs == null) return;
    unawaited(prefs.setInt(_kLoginMs, _ms(now)));
  }

  static int? secondsSinceLogin({DateTime? now}) {
    final at = _prefs?.getInt(_kLoginMs);
    if (at == null) return null;
    final s = (_ms(now) - at) ~/ 1000;
    return s < 0 ? null : s;
  }

  static int _ms(DateTime? now) =>
      (now ?? DateTime.now()).millisecondsSinceEpoch;

  static Future<void> _setOrRemove(String key, String? value) async {
    final prefs = _prefs;
    if (prefs == null) return;
    if (value == null || value.isEmpty) {
      await prefs.remove(key);
    } else {
      await prefs.setString(
        key,
        value.length <= 100 ? value : value.substring(0, 100),
      );
    }
  }

  /// Null before [start] -> an unstarted process reports no count rather than a false zero.
  static int? _bump(String key) {
    final prefs = _prefs;
    if (prefs == null) return null;
    final n = (prefs.getInt(key) ?? 0) + 1;
    unawaited(prefs.setInt(key, n));
    return n;
  }

  /// The facts a phone keeps between launches, as the LAST process read them -> primed before
  /// `setup()` so a relaunch's first `login_attempt` carries them; the probe overwrites them.
  static Map<String, Object> get lastDeviceFacts {
    final raw = _prefs?.getString(_kLastFacts);
    if (raw == null) return const {};
    try {
      return {
        for (final MapEntry(:key, :value) in (jsonDecode(raw) as Map).entries)
          if (key is String &&
              (value is num || value is bool || value is String))
            key: value as Object,
      };
    } catch (_) {
      return const {};
    }
  }

  static const _stableFacts = [
    'gms_version',
    'gms_status',
    'play_store_version',
    'abi',
    'upi_apps',
  ];

  /// The phone at the moment of the probe, empty until [probeDeviceFacts] has landed.
  static Map<String, Object> get deviceFacts => _deviceFacts;
  static Map<String, Object> _deviceFacts = const {};
  static Future<Map<String, Object>>? _deviceProbe;
  static var _deviceLanded = Completer<Map<String, Object>>();

  /// Completes when the device facts land, WITHOUT starting the probe — for the registrar, which
  /// must not be the thing that puts native work on the launch path.
  static Future<Map<String, Object>> get onDeviceFacts => _deviceLanded.future;

  /// Starts the one device probe of the process. Callers pick a moment off the critical path: the
  /// sign-in attempt once Google's surface is requested, or a delay after the first frame.
  static Future<Map<String, Object>> probeDeviceFacts() =>
      _deviceProbe ??= _askDevice();

  /// Native key -> property name; anything absent or of another type is left out, never guessed.
  static const _deviceKeys = {
    'gmsVersion': 'gms_version',
    'gmsStatus': 'gms_status',
    'playStoreVersion': 'play_store_version',
    'powerSaver': 'power_saver',
    'bootAgeMin': 'boot_age_min',
    'availMemMb': 'avail_mem_mb',
    'lowMemNow': 'low_mem_now',
    'freeStorageMb': 'free_storage_mb',
    'batteryPct': 'battery_pct',
    'charging': 'charging',
    'abi': 'abi',
    'thermal': 'thermal',
    'launchSource': 'launch_source',
  };

  static Future<Map<String, Object>> _askDevice() async {
    final out = <String, Object>{};
    var answered = false;
    try {
      final raw = await _buildInfo.invokeMapMethod<String, Object?>(
        'analyticsFacts',
      );
      answered = raw != null;
      for (final MapEntry(:key, :value) in _deviceKeys.entries) {
        if (raw?[key] case final Object v
            when v is num || v is bool || v is String) {
          out[value] = v;
        }
      }
      // The process's age minus our own clock = the engine's share before `main()` ran.
      if (raw?['procAgeMs'] case final int age when age >= msSinceLaunch) {
        out['ms_before_main'] = age - msSinceLaunch;
      }
    } catch (_) {
      // No channel (`flutter test`) or an OEM refusal -> the columns stay absent, never guessed.
    }
    // Same channel: when it did not answer, Data Saver's own fallback `false` would be a guess.
    if (answered) out['data_saver'] = await DataSaver.refresh();
    final upi = await UpiApps.codes();
    if (upi != null) out['upi_apps'] = upi;
    _deviceFacts = Map.unmodifiable(out);
    unawaited(
      _prefs?.setString(
        _kLastFacts,
        jsonEncode({
          for (final key in _stableFacts)
            if (out[key] case final Object v) key: v,
        }),
      ),
    );
    debugPrint('[JourneyStamps] device facts: $_deviceFacts');
    if (!_deviceLanded.isCompleted) _deviceLanded.complete(_deviceFacts);
    return _deviceFacts;
  }

  /// The link as of the latest [probeNetwork]: `net_kbps`/`net_up_kbps` (the modem's estimates, 0
  /// when no network is up), `net_validated` (Android proved internet over it), VPN and metering.
  static Map<String, Object> get networkFacts => _networkFacts;
  static Map<String, Object> _networkFacts = const {};

  /// Drops the reading, so an attempt never reports the previous one's link.
  static void forgetNetwork() => _networkFacts = const {};

  static Future<void> probeNetwork() async {
    forgetNetwork();
    try {
      final raw = await _buildInfo.invokeMapMethod<String, Object?>(
        'networkFacts',
      );
      // No `connected` key = the read itself failed natively, which is not "offline" either.
      if (raw == null || !raw.containsKey('connected')) return;
      final connected = raw['connected'] == true;
      _networkFacts = {
        'net_kbps': connected ? (raw['downKbps'] as int? ?? 0) : 0,
        'net_validated': connected && raw['validated'] == true,
        if (connected) ...{
          'net_up_kbps': ?(raw['upKbps'] as int?),
          'net_vpn': ?(raw['vpn'] as bool?),
          'net_metered': ?(raw['metered'] as bool?),
        },
      };
      debugPrint('[JourneyStamps] network: $_networkFacts');
    } catch (_) {
      // Unknown stays absent: a failed read is not "offline".
    }
  }

  @visibleForTesting
  static void debugSetFacts({
    Map<String, Object> device = const {},
    Map<String, Object> network = const {},
  }) {
    _deviceFacts = device;
    _networkFacts = network;
  }

  @visibleForTesting
  static void debugReset() {
    _prefs = null;
    _slowFrames = 0;
    _worstFrameMs = 0;
    _wallClip = null;
    _clipArm = null;
    _pickerOpens = 0;
    _pickedApp = null;
    _defaultApp = null;
    _launchN = 0;
    _installAgeD = 0;
    _pausedN = 0;
    _resumedAtMs = 0;
    _pausedAtOutcome = null;
    _lifecycle?.dispose();
    _lifecycle = null;
    _deviceFacts = const {};
    _deviceProbe = null;
    _deviceLanded = Completer<Map<String, Object>>();
    _networkFacts = const {};
    _clock
      ..stop()
      ..reset();
  }
}
