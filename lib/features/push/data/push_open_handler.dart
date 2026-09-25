import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../../../core/analytics/analytics_service.dart';
import '../../../core/api/api_client.dart';
import '../../../core/crash/crash_reporter.dart';
import '../../../core/deeplink/deep_link_target.dart';
import '../domain/push_payload.dart';

/// Turns a tapped campaign notification into a screen, and reports the tap.
///
/// TWO TAP PATHS, and both are required on a real phone before this ships:
///   * app dead → the tap launches `MainActivity` and the payload arrives via [getInitialMessage];
///   * app alive in the background → `onMessageOpenedApp` fires.
///
/// `MainActivity` carries `clearTaskOnLaunch` (it fixes a stale-Google-picker defect and must not be
/// removed), and `onNewIntent` does not fire on a launcher relaunch — so the background path is the
/// one that can silently lose a payload. Whichever way it arrives, it ends in [_open].
///
/// **The foreground is ignored on purpose.** A notification posted over the app the person is already
/// using is an interruption that answers nothing; `onMessage` only logs.
///
/// **Nothing here can throw its way onto the screen.** An unreadable payload, a deleted wallpaper, a
/// retired category — all of them open the app. The person tapped a notification we chose to send;
/// landing somewhere is the floor.
class PushOpenHandler {
  PushOpenHandler({
    required ApiClient apiClient,
    required this._analytics,
    required this._crash,
    required this.onOpen,
    this._messaging,
    this._openedStream,
    this._foregroundStream,
    this._getInitialMessage,
  }) : _api = apiClient;

  final ApiClient _api;
  final AnalyticsService _analytics;
  final CrashReporter _crash;

  /// Injected by tests; resolved lazily in a real build so `flutter test` never touches the SDK.
  final FirebaseMessaging? _messaging;

  /// The two message streams are STATIC on `FirebaseMessaging`, so they cannot be injected with the
  /// instance — they are taken separately, which is also what lets a test drive a tap.
  final Stream<RemoteMessage>? _openedStream;
  final Stream<RemoteMessage>? _foregroundStream;

  /// The cold-tap read, for tests: `FirebaseMessaging.instance` never resolves under `flutter test`.
  final Future<RemoteMessage?> Function()? _getInitialMessage;

  /// Every readable target, whatever the app is showing — routing is [PushTapRouter]'s alone.
  final void Function(DeepLinkTarget target) onOpen;

  StreamSubscription<RemoteMessage>? _opened;
  StreamSubscription<RemoteMessage>? _foreground;

  /// Campaign ids already reported this process — `getInitialMessage()` replays the launch message
  /// on a relaunch, and an open is one per person per campaign, not one per replay.
  final Set<String> _reported = <String>{};

  /// Start listening. Call BEFORE the router resolves the launch, for the same reason the local
  /// notification service is constructed before `runApp`: a tap that LAUNCHED the app has to find a
  /// live handler, and the cold tap is the one that matters.
  Future<void> start() async {
    try {
      _opened = (_openedStream ?? FirebaseMessaging.onMessageOpenedApp).listen(
        _open,
        onError: (Object e, StackTrace s) =>
            _crash.recordError(e, s, reason: 'push onMessageOpenedApp'),
      );
      _foreground = (_foregroundStream ?? FirebaseMessaging.onMessage).listen(
        (m) => debugPrint(
          '[Push] foreground message ignored: ${m.data['campaign_id']}',
        ),
        onError: (Object _, StackTrace _) {},
      );
      final initial =
          await (_getInitialMessage ??
              (_messaging ?? FirebaseMessaging.instance).getInitialMessage)();
      if (initial != null) _open(initial);
    } catch (error, stack) {
      // No Play services, or a plugin that could not register. The app keeps working; this phone
      // simply never receives a campaign.
      _crash.recordError(error, stack, reason: 'push open handler start');
    }
  }

  void _open(RemoteMessage message) {
    try {
      final data = Map<String, Object?>.from(message.data);
      final target = pushTargetFor(data);
      final campaignId = pushCampaignId(data);
      debugPrint('[Push] opened campaign=$campaignId dest=${data['dest']}');

      // Null is `home`, or anything this build cannot read. The app is already opening; that IS the
      // destination. Reported all the same — a home campaign's opens are still its opens.
      if (target != null) onOpen(target);

      if (campaignId != null) _report(campaignId, data);
    } catch (error, stack) {
      _crash.recordError(error, stack, reason: 'push tap handling');
    }
  }

  void _report(String campaignId, Map<String, Object?> data) {
    if (!_reported.add(campaignId)) return;
    // The Worker's row is what the CMS's "Opened" number reads; GA4 is the independent copy.
    // Fire-and-forget: a tap must never wait on a request, and a dropped report costs one number.
    unawaited(
      _api
          .post('/me/push-opened', body: {'campaign_id': campaignId})
          .catchError((Object error) {
            _crash.log('push-opened report failed: $error');
            return <String, dynamic>{};
          }),
    );
    _analytics.track(
      'push_opened',
      properties: {
        'campaign_id': campaignId,
        'dest': data['dest'] ?? 'home',
        'id': data['id'],
        'lang': pushLang(data),
      },
    );
  }

  void dispose() {
    unawaited(_opened?.cancel());
    unawaited(_foreground?.cancel());
    _opened = null;
    _foreground = null;
  }
}
