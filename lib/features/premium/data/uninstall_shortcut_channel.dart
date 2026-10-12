import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// What the phone did with a sync. A [pinned] copy sits on a home screen, where the app can never
/// remove it; [rateLimited] means Android refused the call for now.
@immutable
class UninstallShortcutState {
  const UninstallShortcutState({
    required this.published,
    required this.pinned,
    required this.rateLimited,
  });

  final bool published;
  final bool pinned;
  final bool rateLimited;

  static UninstallShortcutState? fromMap(Object? raw) {
    if (raw is! Map) return null;
    return UninstallShortcutState(
      published: raw['published'] == true,
      pinned: raw['pinned'] == true,
      rateLimited: raw['rateLimited'] == true,
    );
  }
}

/// The long-press "Uninstall" item (`android/.../shortcut/UninstallShortcut.kt`). Every call fails
/// soft: a shortcut is never worth an error on screen.
class UninstallShortcutChannel {
  const UninstallShortcutChannel();

  static const _channel = MethodChannel(
    'com.hsrutility.arul/uninstall_shortcut',
  );

  /// The tap kinds [takePendingTap] answers.
  static const tapOffer = 'offer';
  static const tapAppInfo = 'app_info';

  Future<UninstallShortcutState?> sync({
    required bool publish,
    required String shortLabel,
    required String longLabel,
  }) async {
    try {
      return UninstallShortcutState.fromMap(
        await _channel.invokeMethod<Object?>('sync', {
          'publish': publish,
          'shortLabel': shortLabel,
          'longLabel': longLabel,
        }),
      );
    } on PlatformException catch (e) {
      debugPrint('[UninstallShortcut] sync failed: $e');
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// [tapOffer] when an "Uninstall" tap waits for Dart to decide, [tapAppInfo] when the native side
  /// already opened App info; null when no tap is parked. Taking it clears it.
  Future<String?> takePendingTap() async {
    try {
      return await _channel.invokeMethod<String>('takePendingTap');
    } on PlatformException catch (e) {
      debugPrint('[UninstallShortcut] takePendingTap failed: $e');
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Arul's App info page, which holds the phone's own Uninstall button. False when nothing opened.
  Future<bool> openAppInfo() async {
    try {
      return await _channel.invokeMethod<bool>('openAppInfo') ?? false;
    } on PlatformException catch (e) {
      debugPrint('[UninstallShortcut] openAppInfo failed: $e');
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
