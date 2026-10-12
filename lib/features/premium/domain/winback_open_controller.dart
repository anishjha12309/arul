import 'dart:async';

import '../../../core/launch/launch_moment.dart';
import 'entitlement.dart';
import 'winback_reach.dart';

enum WinbackOpenOutcome {
  alreadyEvaluated,
  switchedOff,
  blocked,
  notReachable,
  momentTaken,
  shown,
}

/// The ₹99 sheet's one ask per process ([docs/winback-reach.md]): only for someone whose
/// premium has run out, and only when no other unrequested surface has taken this launch.
class WinbackOpenController {
  WinbackOpenController({
    required this._moment,
    required this._entitlement,
    required this._flags,
  });

  final LaunchMoment _moment;
  final Future<Entitlement> Function() _entitlement;
  final WinbackReachFlags Function() _flags;

  /// A slow `/me` costs this launch's sheet, never a sheet that pops up long after the feed settled.
  static const entitlementWait = Duration(seconds: 8);

  bool _evaluated = false;

  /// [surfaceClear] is re-read after `/me` answers: a sheet or a dialog can arrive meanwhile.
  Future<WinbackOpenOutcome> maybeShow({
    required bool Function() surfaceClear,
    required void Function() open,
  }) async {
    if (_evaluated) return WinbackOpenOutcome.alreadyEvaluated;
    _evaluated = true;
    if (!_flags().openSheet) return WinbackOpenOutcome.switchedOff;
    if (!surfaceClear()) return WinbackOpenOutcome.blocked;
    Entitlement? me;
    try {
      me = await _entitlement().timeout(entitlementWait);
    } catch (_) {
      // Offline or slow: no verdict, no sheet.
    }
    if (!winbackReachable(me)) return WinbackOpenOutcome.notReachable;
    if (!surfaceClear()) return WinbackOpenOutcome.blocked;
    if (!_moment.take('winback_open')) return WinbackOpenOutcome.momentTaken;
    open();
    return WinbackOpenOutcome.shown;
  }
}
