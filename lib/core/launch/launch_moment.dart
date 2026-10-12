import 'package:flutter_riverpod/flutter_riverpod.dart';

/// One unrequested surface per launch: the push-permission ask, Play's review sheet or the daily ₹99
/// sheet, whichever claims it first. The others wait for a later cold open.
class LaunchMoment {
  String? _takenBy;

  String? get takenBy => _takenBy;

  /// Claims this launch's moment for [who]; false when another surface already has it.
  bool take(String who) {
    if (_takenBy != null) return false;
    _takenBy = who;
    return true;
  }
}

/// One per process: the container lives as long as the app does.
final launchMomentProvider = Provider<LaunchMoment>((ref) => LaunchMoment());
