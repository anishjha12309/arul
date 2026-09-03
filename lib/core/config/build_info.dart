import 'package:flutter/foundation.dart' show kDebugMode, visibleForTesting;
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
/// **Fails CLOSED**: an unresolvable installer answers `true` -> every caller hides something that
/// must be absent from the store build.
@Riverpod(keepAlive: true)
Future<bool> isPlayInstall(Ref ref) async {
  try {
    return await _channel.invokeMethod<bool>('isPlayInstall') ?? true;
  } on MissingPluginException {
    // No platform channel -> `flutter test` or a host build -> not a store build.
    return false;
  } on PlatformException {
    return true;
  }
}

/// Whether this phone is a low-memory device — the Android Go flag, under 4.5 GiB of total RAM, or
/// the OS's own memory-pressure flag (the native side owns the rule, [MainActivity.isLowRamDevice]).
///
/// The auth screens read it to show the splash's still poster instead of the looping video.
/// One answer per process -> asked once, cached; every later caller gets the same future.
/// **Fails OPEN** to `false`: no channel (`flutter test`), a platform error, anything unexpected ->
/// the phone is treated as ordinary and gets the video, never a missing background.
abstract final class DeviceMemory {
  static Future<bool>? _isLow;

  static Future<bool> get isLow => _isLow ??= _probe();

  static Future<bool> _probe() async {
    try {
      return await _channel.invokeMethod<bool>('isLowRamDevice') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Drop the cached answer so a test can re-probe under a different mock.
  @visibleForTesting
  static void resetForTesting() => _isLow = null;
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
