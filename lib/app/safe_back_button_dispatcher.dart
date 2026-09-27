import 'package:flutter/widgets.dart';

/// The system Back, with go_router's own pop failure contained.
/// Here the failure is recorded NON-fatal and Back gets the answer a working pop would give at that
/// moment: pop the root navigator when it can, otherwise decline and let the system handle it.
/// Predictive back commits through the same `handlePopRoute`, so it is covered too.
class SafeBackButtonDispatcher extends RootBackButtonDispatcher {
  SafeBackButtonDispatcher({
    required this.rootNavigator,
    required this.onError,
  });

  /// The router's root navigator — the one navigator that exists whatever the shells are doing.
  final GlobalKey<NavigatorState> rootNavigator;

  final void Function(Object error, StackTrace stack) onError;

  @override
  Future<bool> invokeCallback(Future<bool> defaultValue) async {
    try {
      return await super.invokeCallback(defaultValue);
    } catch (error, stack) {
      onError(error, stack);
      final navigator = rootNavigator.currentState;
      if (navigator == null || !navigator.canPop()) return false;
      return navigator.maybePop();
    }
  }
}
