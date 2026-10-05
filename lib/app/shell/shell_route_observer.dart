import 'package:flutter/widgets.dart';

/// Root-navigator observer: tells the shell when a full screen covers it and when it comes back.
/// PageRoute-only on purpose -> a dialog or sheet over a reel must not pause it.
final RouteObserver<PageRoute<dynamic>> shellRouteObserver =
    RouteObserver<PageRoute<dynamic>>();
