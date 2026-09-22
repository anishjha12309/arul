import 'package:flutter/foundation.dart'
    show debugPrint, kDebugMode, visibleForTesting;
import 'package:flutter/services.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'build_info.g.dart';

const _channel = MethodChannel('com.hsrutility.arul/build_info');

/// Whether this build came from Google Play — the uploaded `.aab`, not a sideloaded APK.
///
/// No BuildConfig signal separates an APK from an AAB (both are `release`) -> the installer package
/// is the runtime proxy -> only a Play install reports `com.android.vending`.
/// FLAG_SECURE already rides the same check -> the native side owns it ([MainActivity.isPlayInstall])
/// -> the two can never disagree.
///
/// ONE probe per process, shared by every caller ([PlayInstall]) -> the QA-tools gate and the
/// PostHog gate can never answer differently about the same build.
@Riverpod(keepAlive: true)
Future<bool> isPlayInstall(Ref ref) => PlayInstall.resolved;

/// The Play-install answer, asked once and cached for the process.
///
/// Two callers need it in two shapes: [qaToolsEnabled] can await it, and the analytics assembly
/// cannot — it is a synchronous provider that runs on the first `track()`. So the probe is kicked
/// off in `main()` and its verdict parked in [isPlay], the same shape `AnalyticsCohort.isMember`
/// already uses for the same reason.
///
/// **Fails toward PLAY.** An unresolvable installer or a platform error answers `true`: the two
/// consumers want opposite safety, and the one that matters more is the analytics gate — a real
/// user's events must never be dropped because a channel hiccuped. The QA tools read `== false`, so
/// the same answer hides them, which is also the safe direction there.
/// A MISSING channel is different from a failing one: no platform at all is `flutter test` or a host
/// build, which is not a store build and must stay silent.
abstract final class PlayInstall {
  static Future<bool>? _probe;

  /// The verdict, defaulting to Play until the probe lands. Read synchronously by the analytics
  /// assembly; `main()` awaits [resolved] before the SDK starts, so no event is ever gated on the
  /// default in a shipped build.
  static bool get isPlay => _isPlay;
  static bool _isPlay = true;

  /// The probe, started once. Later callers get the same future.
  static Future<bool> get resolved => _probe ??= _ask();

  static Future<bool> _ask() async {
    final play = await _invoke();
    _isPlay = play;
    return play;
  }

  static Future<bool> _invoke() async {
    try {
      return await _channel.invokeMethod<bool>('isPlayInstall') ?? true;
    } on MissingPluginException {
      // No platform channel -> `flutter test` or a host build -> not a store build.
      return false;
    } on PlatformException {
      return true;
    }
  }

  /// Pins the answer without a channel, for tests that assert the gate rather than the probe.
  @visibleForTesting
  static void debugSetIsPlay(bool value) {
    _isPlay = value;
    _probe = Future<bool>.value(value);
  }

  /// Drop the cached answer so a test can re-probe under a different mock.
  @visibleForTesting
  static void resetForTesting() {
    _isPlay = true;
    _probe = null;
  }
}

/// How much this phone can afford: the ONE quality answer the app spends against.
///
/// Three rungs, resolved once per process by the native table in [MainActivity.deviceTier].
/// `low` is EXACTLY the shipped poster rule (the Go flag, under 4.5 GiB, Android 12L and older) and
/// nothing may widen it — that population is what the sign-in funnel is read against.
///
/// **Tier changes COST, never composition.** No layout branches on it.
enum DeviceTier {
  low,
  mid,
  high;

  /// Parses the native string. Anything unrecognised is [mid] — the fail-open rung.
  static DeviceTier parse(String? name) => switch (name) {
    'low' => DeviceTier.low,
    'high' => DeviceTier.high,
    _ => DeviceTier.mid,
  };
}

/// The device tier, asked once and cached for the process.
///
/// **Fails open to [DeviceTier.mid]** on every failure path — no channel (`flutter test`), a
/// platform error, an unparseable answer. Never to `low`, which would cripple a capable phone over
/// a failed probe; never to `high`, which would overcommit a weak one.
///
/// The probe is kicked off in `main()`. [resolved] is the synchronous read for the two callers that
/// cannot await — the image-cache ceiling and the feed's decoder budget — and answers `mid` until
/// the probe lands, which is within the splash.
abstract final class DeviceQuality {
  static Future<DeviceTier>? _probe;

  static Future<DeviceTier> get tier => _probe ??= _ask();

  /// The verdict once the probe has landed, else [DeviceTier.mid]. Never null: every caller wants a
  /// number to spend against, and `mid` is the answer a failed probe gives anyway.
  static DeviceTier get resolved => _resolved ?? DeviceTier.mid;
  static DeviceTier? _resolved;

  /// True once the probe has actually answered — separates "mid" from "not asked yet".
  static bool get isResolved => _resolved != null;

  /// The diagnostic facts behind the rung, logged once per process so a phone that lands on an
  /// unexpected tier can be identified from one logcat line.
  static Map<String, Object?> get facts => Map.unmodifiable(_facts);
  static final Map<String, Object?> _facts = {};

  static Future<DeviceTier> _ask() async {
    try {
      final info = await _channel.invokeMapMethod<String, Object?>(
        'deviceTier',
      );
      final tier = DeviceTier.parse(info?['tier'] as String?);
      _facts
        ..clear()
        ..addAll(info ?? const {});
      _resolved = tier;
      debugPrint(
        'DeviceTier resolved: ${tier.name} '
        '(totalMem=${info?['totalMem']} sdk=${info?['sdkInt']} '
        'lowRamFlag=${info?['lowRamFlag']} soc=${info?['soc']})',
      );
      return tier;
    } catch (e) {
      // Catches EVERYTHING, not just the two channel exceptions: a binding that is not up yet
      // throws a plain `FlutterError`, and this answer must never fail a launch.
      _resolved = DeviceTier.mid;
      debugPrint('DeviceTier resolved: mid (probe failed: $e)');
      return DeviceTier.mid;
    }
  }

  /// Pins the tier without a channel, for tests that assert a consumer rather than the probe.
  @visibleForTesting
  static void debugSetTier(DeviceTier value) {
    _resolved = value;
    _probe = Future<DeviceTier>.value(value);
  }

  /// Drop the cached answer so a test can re-probe under a different mock.
  @visibleForTesting
  static void resetForTesting() {
    _probe = null;
    _resolved = null;
    _facts.clear();
  }
}

/// The device tier as a provider, for widgets and providers that want to watch it.
/// Same single probe behind it — a widget and `main()` can never read different tiers.
@Riverpod(keepAlive: true)
Future<DeviceTier> deviceTier(Ref ref) => DeviceQuality.tier;

/// Whether this phone takes the poster path — DERIVED from [DeviceQuality]: `tier == low`.
///
/// The rule itself lives in the native table ([MainActivity.deviceTier]), whose `low` rung is the
/// Android Go flag, under 4.5 GiB of total RAM, or Android 12L and older; never the OS's momentary
/// pressure flag (the reason is on [MainActivity.isLowRamDevice]).
///
/// The auth screens read it to show the splash's still poster instead of the looping video.
/// One answer per process -> asked once, cached; every later caller gets the same future.
/// **Fails OPEN** to `false`: the tier probe fails to `mid`, so an unexpected phone is treated as
/// ordinary and gets the video, never a missing background.
abstract final class DeviceMemory {
  static Future<bool> get isLow async =>
      (await DeviceQuality.tier) == DeviceTier.low;

  /// The verdict once the probe has landed, else null. Read by the sign-in events, which fire
  /// after the splash already awaited [isLow] -> stamped on every install that reached the wall.
  /// Null until the tier lands, exactly as before — `?DeviceMemory.resolved` drops the key then.
  static bool? get resolved => DeviceQuality.isResolved
      ? DeviceQuality.resolved == DeviceTier.low
      : null;

  /// Drop the cached answer so a test can re-probe under a different mock.
  @visibleForTesting
  static void resetForTesting() => DeviceQuality.resetForTesting();
}

/// The device's `Build.VERSION.SDK_INT`, or null where there is no platform (`flutter test`).
///
/// Stamped on the push registry row ([PushRegistration]) so a delivery gap can be read per Android
/// generation: the permission model, the channel rules and the trampoline rules all change with it,
/// and no other field on the row says which phone this is.
/// One probe per process — the answer cannot change while the app is running.
abstract final class AndroidVersion {
  static Future<int?>? _probe;

  static Future<int?> get sdkInt => _probe ??= _ask();

  /// Catches EVERYTHING, not just the two channel exceptions: this answers one diagnostic column on
  /// the push registry row, and the registration that carries it must never be lost to a probe.
  /// A binding that is not up yet throws a plain `FlutterError` from `defaultBinaryMessenger`, which
  /// a narrow `on PlatformException` would let straight through.
  static Future<int?> _ask() async {
    try {
      return await _channel.invokeMethod<int>('androidSdkInt');
    } catch (_) {
      return null;
    }
  }

  /// Drop the cached answer so a test can re-probe under a different mock.
  @visibleForTesting
  static void resetForTesting() => _probe = null;
}

/// Whether the on-device QA affordances (fire a test notification, preview every reminder, inspect
/// what is actually armed) should be reachable.
///
/// True in debug AND in a **sideloaded release APK**, false in the Play build.
/// The APK case is the point: R8 resource shrinking is what strips the notification icons -> a
/// `kDebugMode` gate hid the one screen that could catch it, in exactly the build where it breaks.
/// Real users only ever get the AAB -> they still never see these.
/// A loading or failed answer resolves to false -> the tools appear a frame late on a release APK
/// rather than ever flashing up in the store build.
@Riverpod(keepAlive: true)
bool qaToolsEnabled(Ref ref) {
  if (kDebugMode) return true;
  // `== false`, not `!= true` -> a loading or errored snapshot is null -> it must resolve to "hide".
  return ref.watch(isPlayInstallProvider).value == false;
}
