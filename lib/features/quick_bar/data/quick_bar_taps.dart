import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../../core/deeplink/deep_link_target.dart';
import 'quick_bar_channel.dart';

/// Opens the tab a Quick Access button parked natively, taken on start and on every resume.
///
/// Never a link: in a task Android restored after killing the process, the tap reaches MainActivity
/// through onNewIntent before the router exists, and Flutter drops the route (docs/quick-bar.md).
class QuickBarTaps {
  QuickBarTaps({required this._channel, required this.onOpen});

  final QuickBarChannel _channel;

  final void Function(DeepLinkTarget target) onOpen;

  AppLifecycleListener? _lifecycle;

  void start() {
    _lifecycle = AppLifecycleListener(onResume: () => unawaited(take()));
    unawaited(take());
  }

  @visibleForTesting
  Future<void> take() async {
    final tab = switch (await _channel.takePendingTab()) {
      'wallpapers' => ArulTab.wallpapers,
      'ringtones' => ArulTab.ringtones,
      'status' => ArulTab.status,
      _ => null,
    };
    if (tab != null) {
      onOpen(TabLinkTarget(tab, source: DeepLinkSource.quickBar));
    }
  }

  void dispose() => _lifecycle?.dispose();
}
