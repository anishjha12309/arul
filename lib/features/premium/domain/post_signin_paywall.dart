import 'package:flutter/foundation.dart';

/// The after-sign-in paywall test: whether THIS sign-in should open `/premium` before the feed.
///
/// The Worker picks the side once, on the account-creating `POST /auth/login`, and only for a new
/// account that can still start a free trial (`workers/src/lib/paywall-test.ts`). The app never
/// decides who is in — it only says it CAN show the paywall ([requestFlag]) and obeys the answer.
///
/// In memory on purpose: a process that dies between the sign-in and the feed's first frame drops
/// it, and the paywall never ambushes a later cold start of an app the person already uses.
abstract final class PostSigninPaywall {
  /// Login-body key announcing that this build shows the paywall -> older builds never enter the test.
  static const requestFlag = 'postSigninPaywall';

  /// The `paywall_test` value on `login_success`, and the `?source=` of the `/premium` it opens.
  static const source = 'post_signin';

  /// Test seam: `--dart-define=DEBUG_PAYWALL_TEST=paywall` stands in for the Worker's side.
  /// Only a brand-new account is ever assigned one -> this walks the flow with an existing account.
  /// Const-gated on kDebugMode -> release builds compile it away.
  static const _debugSide = String.fromEnvironment('DEBUG_PAYWALL_TEST');

  static bool _pending = false;

  /// Record the Worker's side for the sign-in that just succeeded. Only `'paywall'` opens anything.
  static void note(String? side) {
    final effective = kDebugMode && _debugSide.isNotEmpty ? _debugSide : side;
    _pending = effective == 'paywall';
  }

  /// True exactly once after a `'paywall'` sign-in -> the caller opens `/premium`.
  static bool take() {
    final pending = _pending;
    _pending = false;
    return pending;
  }
}
