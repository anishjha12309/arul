import 'dart:async';

import '../../../core/launch/launch_moment.dart';
import 'entitlement.dart';
import 'winback_ledger.dart';
import 'winback_reach.dart';

enum WinbackDailyOutcome {
  alreadyEvaluated,
  switchedOff,
  blocked,
  notReachable,
  notToday,
  momentTaken,
  shown,
}

/// The daily ₹99 sheet's one ask per process ([docs/winback-reach.md]): only for someone whose
/// premium has run out, at most once per IST day, and only when no other unrequested surface has
/// taken this launch.
class WinbackDailyController {
  WinbackDailyController({
    required this._ledger,
    required this._moment,
    required this._entitlement,
    required this._flags,
  });

  final WinbackLedger _ledger;
  final LaunchMoment _moment;
  final Future<Entitlement> Function() _entitlement;
  final WinbackReachFlags Function() _flags;

  /// A slow `/me` costs this launch's sheet, never a sheet that pops up long after the feed settled.
  static const entitlementWait = Duration(seconds: 8);

  bool _evaluated = false;

  /// [surfaceClear] is re-read after `/me` answers: a sheet or a dialog can arrive meanwhile.
  Future<WinbackDailyOutcome> maybeShow({
    required bool Function() surfaceClear,
    required void Function() open,
  }) async {
    if (_evaluated) return WinbackDailyOutcome.alreadyEvaluated;
    _evaluated = true;
    if (!_flags().dailySheet) return WinbackDailyOutcome.switchedOff;
    if (!surfaceClear()) return WinbackDailyOutcome.blocked;
    Entitlement? me;
    try {
      me = await _entitlement().timeout(entitlementWait);
    } catch (_) {
      // Offline or slow: no verdict, no sheet.
    }
    if (!winbackReachable(me)) return WinbackDailyOutcome.notReachable;
    if (!_ledger.canAutoShow()) return WinbackDailyOutcome.notToday;
    if (!surfaceClear()) return WinbackDailyOutcome.blocked;
    if (!_moment.take('winback_daily')) return WinbackDailyOutcome.momentTaken;
    open();
    return WinbackDailyOutcome.shown;
  }
}
