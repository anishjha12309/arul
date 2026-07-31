import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/services.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'build_info.g.dart';

const _channel = MethodChannel('com.hsrapps.arul/build_info');

/// Whether this build was delivered by Google Play — i.e. whether it is the
/// uploaded `.aab` rather than a sideloaded APK.
///
/// There is no BuildConfig signal that separates an APK from an AAB (both are
/// the `release` build type), so the installer package is the runtime proxy:
/// only Play installs report `com.android.vending`. The native side owns the
/// check ([MainActivity.isPlayInstall]) because FLAG_SECURE already depends on
/// it and the two must never disagree.
///
/// **Fails CLOSED** — an unresolvable installer answers `true`. Every caller
/// gates something that should be absent from the store build, so "assume this
/// is the store build" is the only safe unknown.
@Riverpod(keepAlive: true)
Future<bool> isPlayInstall(Ref ref) async {
  try {
    return await _channel.invokeMethod<bool>('isPlayInstall') ?? true;
  } on MissingPluginException {
    // No platform channel — `flutter test`, or a host build. Not a store build.
    return false;
  } on PlatformException {
    return true;
  }
}

/// Whether the on-device QA affordances (fire a test notification, preview every
/// reminder, inspect what is actually armed) should be reachable.
///
/// True in debug AND in a **sideloaded release APK**, false in the Play build.
///
/// The APK case is the point. These tools verify things that only behave
/// correctly in a release build — R8 resource shrinking is what strips the
/// notification icons, and a `kDebugMode` gate hid the one screen that could
/// have caught it in exactly the build where it breaks. Real users, who only
/// ever get the AAB, still never see them.
///
/// A loading or failed answer resolves to false: the tools appear a frame late
/// on a release APK rather than ever flashing up in the store build.
@Riverpod(keepAlive: true)
bool qaToolsEnabled(Ref ref) {
  if (kDebugMode) return true;
  // `== false`, not `!= true`: a loading or errored snapshot has a null value
  // and must resolve to "hide", matching the fail-closed rule above.
  return ref.watch(isPlayInstallProvider).value == false;
}
