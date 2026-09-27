import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter/services.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'build_info.g.dart';

const _channel = MethodChannel('com.hsrutility.arul/build_info');

/// Whether this build came from Google Play — the uploaded `.aab`, not a sideloaded APK.
/// The analytics assembly is a synchronous provider that runs on the first `track()`, so the probe is
/// kicked off in `main()` and its verdict parked in [PlayInstall.isPlay], the same shape
/// `AnalyticsCohort.isMember` already uses for the same reason.
abstract final class PlayInstall {
  static Future<bool>? _probe;

  /// The verdict, defaulting to Play until the probe lands. Read synchronously by the analytics
  /// assembly; `main()` awaits [resolved] before the SDK starts, so no event is ever gated on the
  /// default in a shipped build.
  static bool get isPlay => _isPlay;
  static bool _isPlay = true;

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

  @visibleForTesting
  static void debugSetIsPlay(bool value) {
    _isPlay = value;
    _probe = Future<bool>.value(value);
  }

  @visibleForTesting
  static void resetForTesting() {
    _isPlay = true;
    _probe = null;
  }
}

/// How much this phone can afford: the ONE quality answer the app spends against.
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

  @visibleForTesting
  static void debugSetTier(DeviceTier value) {
    _resolved = value;
    _probe = Future<DeviceTier>.value(value);
  }

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
/// **Fails OPEN** to `false`: the tier probe fails to `mid`, so an unexpected phone is treated as
/// ordinary and gets the video, never a missing background.
abstract final class DeviceMemory {
  static Future<bool> get isLow async =>
      (await DeviceQuality.tier) == DeviceTier.low;

  /// The verdict once the probe has landed, else null. Read by the sign-in events, which fire
  /// after the splash already awaited [isLow] -> stamped on every install that reached the wall.
  static bool? get resolved => DeviceQuality.isResolved
      ? DeviceQuality.resolved == DeviceTier.low
      : null;

  @visibleForTesting
  static void resetForTesting() => DeviceQuality.resetForTesting();
}

/// The device's `Build.VERSION.SDK_INT`, or null where there is no platform (`flutter test`).
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

  @visibleForTesting
  static void resetForTesting() => _probe = null;
}
