import 'package:flutter/foundation.dart';

enum UpdateLaunch { undecided, prompted, clear }

/// Flows the in-app update must never cover (a sign-in sheet, the paywall and its UPI handoff).
abstract final class UpdateHolds {
  static final ValueNotifier<int> active = ValueNotifier<int>(0);

  /// The update outranks Play's review sheet: the review waits while this is `undecided` and yields
  /// the whole launch once it is `prompted` (docs/app-update.md).
  static final ValueNotifier<UpdateLaunch> launch = ValueNotifier(
    UpdateLaunch.clear,
  );

  /// Takes a hold; the returned release is idempotent, so every settle path may call it.
  static VoidCallback hold() {
    active.value++;
    var released = false;
    return () {
      if (released) return;
      released = true;
      active.value--;
    };
  }
}
