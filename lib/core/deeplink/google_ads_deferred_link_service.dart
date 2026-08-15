import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../features/referral/data/install_referrer_service.dart';

/// Receives Google Ads deferred App URLs fetched by Google Analytics for
/// Firebase and feeds them into the app's existing durable wallpaper handoff.
///
/// Native Android buffers a link until this channel attaches. It does not mark
/// the link handled until [InstallReferrerService.queueWallpaperTarget] has
/// persisted the UUID, so a process death cannot turn an ad click into a plain
/// home-screen launch.
class GoogleAdsDeferredLinkService {
  GoogleAdsDeferredLinkService(this._targets, {MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_channelName);

  static const _channelName = 'com.hsrutility.arul/google_ads_deferred_link';

  final InstallReferrerService _targets;
  final MethodChannel _channel;
  final Set<String> _seenTokens = <String>{};

  /// Attach before asking for the initial value: Firebase may write its result
  /// on either side of Flutter engine startup, and native supports both paths.
  Future<void> start() async {
    _channel.setMethodCallHandler(_onNativeCall);
    try {
      final payload = await _channel.invokeMapMethod<String, Object?>(
        'getDeferredDeepLink',
      );
      await _capture(payload);
    } on MissingPluginException {
      // Expected on non-Android platforms and in unit/widget tests.
    } on PlatformException catch (error) {
      debugPrint('[GoogleAdsDeferredLink] initial read failed: $error');
    }
  }

  Future<Object?> _onNativeCall(MethodCall call) async {
    if (call.method != 'onDeferredDeepLink') return null;
    final arguments = call.arguments;
    if (arguments is! Map) return null;
    await _capture(arguments.cast<Object?, Object?>());
    return null;
  }

  Future<void> _capture(Map<Object?, Object?>? payload) async {
    final raw = payload?['url'];
    final rawToken = payload?['token'];
    if (raw is! String || rawToken is! String || rawToken.isEmpty) return;
    if (!_seenTokens.add(rawToken)) return;

    final wallpaperId = parseWallpaperId(raw);
    if (wallpaperId != null) {
      await _targets.queueWallpaperTarget(wallpaperId);
    }

    // ACK malformed links too. Native already validates defensively, but Dart
    // repeats that boundary check; leaving a rejected payload pending would
    // retry it forever on every Activity creation.
    try {
      await _channel.invokeMethod<bool>('ackDeferredDeepLink', {
        'token': rawToken,
      });
    } on MissingPluginException {
      // Test/non-Android no-op.
    } on PlatformException catch (error) {
      debugPrint('[GoogleAdsDeferredLink] acknowledgement failed: $error');
    }
  }

  /// Strictly accepts the same verified HTTPS wallpaper URL as Android.
  @visibleForTesting
  static String? parseWallpaperId(String? raw) {
    if (raw == null) return null;
    final uri = Uri.tryParse(raw.trim());
    if (uri == null ||
        uri.scheme.toLowerCase() != 'https' ||
        uri.host.toLowerCase() != kDeepLinkHost) {
      return null;
    }
    // Empty segments dropped so this accepts exactly what android.net.Uri's
    // getPathSegments() does — it skips them, so a campaign App URL with a
    // trailing slash passes the native check and would then be thrown away here,
    // silently, on the far side of the channel.
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.length != 2 || segments.first != 'w') return null;
    final id = segments[1].toLowerCase();
    return RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
        ).hasMatch(id)
        ? id
        : null;
  }
}
