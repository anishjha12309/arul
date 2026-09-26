import 'dart:async';

import 'package:go_router/go_router.dart';

import '../../../core/deeplink/deep_link_target.dart';

/// Turns a tapped campaign's target into a screen, whatever the app was showing when the tap landed.
///
/// Two failures this exists to prevent:
///   * **A warm tap under a covering route.** A wallpaper or ringtone target only PARKS; the shell and
///     the tab follow it. After a premium push (`go('/premium')`) the shell is not mounted at all, and
///     under a pushed screen (refer, upload, notification settings) it switches branch out of sight.
///     The build-76 production walk tapped a wallpaper campaign there and stayed on the paywall. So a
///     tap past the launch always ends in a `go`, which replaces whatever sits on top.
///   * **A cold tap ahead of the auth decision.** `getInitialMessage()` resolves before the splash has
///     read the stored session, and phones register before sign-in, so a `go('/browse')` there walks a
///     signed-out person past the sign-in wall. While the router is on the splash or sign-in, the
///     destination is HELD and applied the first time the launch reaches any other screen.
class PushTapRouter {
  PushTapRouter({required this._router, required this.onSelectCategory}) {
    _router.routeInformationProvider.addListener(_onRouteChanged);
  }

  final GoRouter _router;

  /// Selects the feed's category — BEFORE routing, so the feed's first build already filters.
  final void Function(String slug) onSelectCategory;

  String? _held;

  static const _launchPaths = {'/', '/sign-in'};

  bool get _atLaunch =>
      _launchPaths.contains(_router.routeInformationProvider.value.uri.path);

  /// Where [target] lands. Last tap wins — a second tap during the launch replaces the first.
  void open(DeepLinkTarget target) {
    switch (target) {
      case CategoryLinkTarget(:final slug):
        onSelectCategory(slug);
      case PremiumLinkTarget():
        break;
      case WallpaperLinkTarget() || RingtoneLinkTarget() || TabLinkTarget():
        // Parked for the tab's screen, which consumes it once its catalog can resolve the id. A held
        // cold tap needs nothing more: the shell follows a parked target when it first mounts.
        ArulDeepLink.requestTarget(target);
    }
    final location = locationFor(target);
    if (_atLaunch) {
      _held = location;
      return;
    }
    _held = null;
    _router.go(location);
  }

  static String locationFor(DeepLinkTarget target) => switch (target) {
    PremiumLinkTarget() => '/premium?source=push',
    _ => target.tab == ArulTab.ringtones ? '/ringtones' : '/browse',
  };

  void _onRouteChanged() {
    final held = _held;
    if (held == null || _atLaunch) return;
    _held = null;
    // Inside the router's own notification -> navigate after it, never re-entrantly.
    scheduleMicrotask(() => _router.go(held));
  }

  void dispose() {
    _router.routeInformationProvider.removeListener(_onRouteChanged);
  }
}
