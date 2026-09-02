import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../features/referral/data/install_referrer_service.dart';
import 'deep_link_parser.dart';
import 'deep_link_target.dart';

/// Receives deferred deep links native Android fetched over the network — GA4F and the Meta SDK.
///
/// Feeds them into the app's existing durable target handoff.
/// Native buffers every link until this channel attaches -> it then pushes each AND answers a pull.
/// A link is not marked handled until [InstallReferrerService.queueRequest] has persisted it.
/// So a process death cannot turn an ad click into a plain home-screen launch.
/// Both sides validate the URL shape; Dart is the one that decides what it MEANS.
class DeferredLinkService {
  DeferredLinkService(this._targets, {MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_channelName);

  static const _channelName = 'com.hsrutility.arul/deferred_link';

  final InstallReferrerService _targets;
  final MethodChannel _channel;
  final Set<String> _seenTokens = <String>{};

  /// GA4F and the Meta SDK may answer on either side of engine startup -> attach BEFORE pulling.
  Future<void> start() async {
    _channel.setMethodCallHandler(_onNativeCall);

    // Test seam: `--dart-define=DEBUG_DEFERRED_LINK=<url>` replays a delivery through the SAME path.
    // So parse → persist → shell → screen → language is drivable over adb without an ad install.
    // Const-gated on kDebugMode -> release builds compile it away.
    const debugLink = String.fromEnvironment('DEBUG_DEFERRED_LINK');
    if (kDebugMode && debugLink.isNotEmpty) {
      await _capture({
        'url': debugLink,
        'token': 'debug:$debugLink',
        'source': DeepLinkSource.debug.key,
      }, ack: false);
    }

    try {
      final payloads = await _channel.invokeListMethod<Object?>(
        'getDeferredDeepLinks',
      );
      for (final payload in payloads ?? const <Object?>[]) {
        if (payload is Map) await _capture(payload.cast<Object?, Object?>());
      }
    } on MissingPluginException {
      // Expected on non-Android platforms and in unit/widget tests.
    } on PlatformException catch (error) {
      debugPrint('[DeferredLink] initial read failed: $error');
    }
  }

  Future<Object?> _onNativeCall(MethodCall call) async {
    if (call.method != 'onDeferredDeepLink') return null;
    final arguments = call.arguments;
    if (arguments is! Map) return null;
    await _capture(arguments.cast<Object?, Object?>());
    return null;
  }

  Future<void> _capture(
    Map<Object?, Object?> payload, {
    bool ack = true,
  }) async {
    final raw = payload['url'];
    final rawToken = payload['token'];
    if (raw is! String || rawToken is! String || rawToken.isEmpty) return;
    // Native pushes on capture AND answers the initial pull -> seeing one delivery twice is NORMAL.
    if (!_seenTokens.add(rawToken)) return;

    final source = switch (payload['source']) {
      'meta' => DeepLinkSource.meta,
      'debug' => DeepLinkSource.debug,
      _ => DeepLinkSource.googleAds,
    };
    final request = parseDeepLink(raw, source: source);
    if (request != null) {
      await _targets.queueRequest(request);
    } else {
      debugPrint('[DeferredLink] ignored (not an Arul link): $raw');
    }

    // A rejected payload left pending retries forever on every Activity creation -> ACK malformed too.
    if (!ack) return;
    try {
      await _channel.invokeMethod<bool>('ackDeferredDeepLink', {
        'token': rawToken,
      });
    } on MissingPluginException {
      // Test/non-Android no-op.
    } on PlatformException catch (error) {
      debugPrint('[DeferredLink] acknowledgement failed: $error');
    }
  }
}
