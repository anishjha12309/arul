import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Whether the phone will actually draw the bar — what the Settings toggle checks before it
/// promises one.
@immutable
class QuickBarStatus {
  const QuickBarStatus({required this.permitted, required this.channelBlocked});

  final bool permitted;

  /// The person blocked the bar's own channel while leaving the app's notifications on.
  final bool channelBlocked;

  bool get visible => permitted && !channelBlocked;

  static QuickBarStatus? fromMap(Object? raw) {
    if (raw is! Map) return null;
    return QuickBarStatus(
      permitted: raw['permitted'] == true,
      channelBlocked: raw['channelBlocked'] == true,
    );
  }
}

/// The bar's words, in the app's language. The native side stores them, because a reboot re-posts
/// the bar with no Flutter alive to ask.
@immutable
class QuickBarLabels {
  const QuickBarLabels({
    required this.channelName,
    required this.wallpapers,
    required this.ringtones,
    required this.status,
  });

  final String channelName;
  final String wallpapers;
  final String ringtones;
  final String status;
}

/// The native Quick Access bar (`android/.../quickbar/QuickBar.kt`). Every call fails soft to null:
/// a bar is never worth an error on screen.
class QuickBarChannel {
  const QuickBarChannel();

  static const _channel = MethodChannel('com.hsrutility.arul/quick_bar');

  Future<QuickBarStatus?> sync({
    required bool on,
    required QuickBarLabels labels,
  }) async {
    try {
      return QuickBarStatus.fromMap(
        await _channel.invokeMethod<Object?>('sync', {
          'on': on,
          'channelName': labels.channelName,
          'wallpapers': labels.wallpapers,
          'ringtones': labels.ringtones,
          'status': labels.status,
        }),
      );
    } on PlatformException catch (e) {
      debugPrint('[QuickBar] sync failed: $e');
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  Future<QuickBarStatus?> status() async {
    try {
      return QuickBarStatus.fromMap(
        await _channel.invokeMethod<Object?>('status'),
      );
    } on PlatformException catch (e) {
      debugPrint('[QuickBar] status failed: $e');
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// The tab a bar button parked (`wallpapers` / `ringtones` / `status`), once; null when none.
  Future<String?> takePendingTab() async {
    try {
      return await _channel.invokeMethod<String>('takePendingTab');
    } on PlatformException catch (e) {
      debugPrint('[QuickBar] takePendingTab failed: $e');
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// The bar's channel settings when only it is blocked, else the app's notification settings.
  Future<void> openSettings() async {
    try {
      await _channel.invokeMethod<void>('openSettings');
    } on PlatformException catch (e) {
      debugPrint('[QuickBar] openSettings failed: $e');
    } on MissingPluginException {
      return;
    }
  }
}
