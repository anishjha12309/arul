import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../../../core/analytics/analytics_service.dart';
import '../../../core/deeplink/deep_link_target.dart';
import '../domain/cancel_offer.dart';
import '../domain/entitlement.dart';
import '../domain/winback_reach.dart';
import 'uninstall_shortcut_channel.dart';

/// The long-press "Uninstall" tap, parked natively and taken on start and on every resume.
///
/// Every landing is the ₹99 sheet (whose "Uninstall anyway" opens App info) or App info itself, so
/// the label stays true; never a link, for the restored-task reason in docs/quick-bar.md.
class UninstallShortcutTaps {
  UninstallShortcutTaps({
    required this._channel,
    required this._router,
    required this._entitlement,
    required this._flags,
    required this._analytics,
  });

  final UninstallShortcutChannel _channel;
  final GoRouter _router;
  final Future<Entitlement> Function() _entitlement;
  final WinbackReachFlags Function() _flags;
  final AnalyticsService _analytics;

  /// A splash that never routes, or a `/me` that never answers, still ends in App info.
  static const holdLimit = Duration(seconds: 15);
  static const entitlementWait = Duration(seconds: 6);

  AppLifecycleListener? _lifecycle;
  bool _landing = false;

  void start() {
    _lifecycle = AppLifecycleListener(onResume: () => unawaited(take()));
    unawaited(take());
  }

  @visibleForTesting
  Future<void> take() async {
    final tap = await _channel.takePendingTap();
    if (tap == null) return;
    ArulDeepLink.noteExternalOpen();
    // The native side already opened App info: there was no ₹99 sheet to offer.
    if (tap == UninstallShortcutChannel.tapAppInfo) {
      _track('app_info');
      return;
    }
    if (_landing) return;
    _landing = true;
    try {
      await _land();
    } finally {
      _landing = false;
    }
  }

  Future<void> _land() async {
    final path = await _pathPastSplash();
    Entitlement? me;
    try {
      me = await _entitlement().timeout(entitlementWait);
    } catch (_) {
      // No verdict: App info below.
    }
    final landing = path == null
        ? ShortcutLanding.appInfo
        : decideShortcutLanding(path: path, entitlement: me, flags: _flags());
    if (landing == ShortcutLanding.offer) {
      _track(const PremiumLinkTarget(source: DeepLinkSource.shortcut).kind);
      unawaited(
        _router.push(
          Uri(
            path: '/premium',
            queryParameters: {
              'source': WinbackEntry.uninstallSource,
              'offer': kWinbackOffer,
            },
          ).toString(),
        ),
      );
      return;
    }
    _track('app_info');
    await _channel.openAppInfo();
  }

  // The splash decides between the feed and the sign-in wall; the tap waits for that, not longer.
  Future<String?> _pathPastSplash() async {
    String current() => _router.routeInformationProvider.value.uri.path;
    if (current() != '/') return current();
    final settled = Completer<String?>();
    void onRoute() {
      if (current() != '/' && !settled.isCompleted) settled.complete(current());
    }

    _router.routeInformationProvider.addListener(onRoute);
    final limit = Timer(holdLimit, () {
      if (!settled.isCompleted) settled.complete(null);
    });
    try {
      return await settled.future;
    } finally {
      limit.cancel();
      _router.routeInformationProvider.removeListener(onRoute);
    }
  }

  void _track(String kind) => _analytics.track(
    'deep_link_opened',
    properties: {'kind': kind, 'source': DeepLinkSource.shortcut.key},
  );

  void dispose() => _lifecycle?.dispose();
}
