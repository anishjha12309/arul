import 'package:flutter/widgets.dart';

/// The system Back, with go_router's own pop failure contained.
///
/// go_router 17.3 `GoRouterDelegate.popRoute` force-unwraps the `currentState` of every shell
/// navigator in the current match, and a shell whose navigator is not mounted yet (a transient state
/// around a redirect or a resume) throws `Null check operator used on a null value`
/// (flutter/flutter#188993). The fix, flutter/packages#12111, is unmerged and 18.0.1 carries the same
/// code. The framework catches the throw in `WidgetsBinding.handlePopRoute`, reports it through
/// `FlutterError` — a FATAL in Crashlytics — and then calls `SystemNavigator.pop()`: a Back that
/// closes the app.
///
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

  /// Where a contained failure is reported (non-fatal).
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
