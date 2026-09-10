import 'package:flutter/foundation.dart';

/// Cold-start / sign-in latency trace.
///
/// The launch path crosses four layers — engine → `main()` → the splash's auth wait → sign-in.
/// Only ONE monotonic clock spanning all of them shows which layer owns the delay.
/// Firebase Performance traces cannot answer that.
/// [mark] is a no-op in release -> the call sites cost nothing to leave in place.
/// Read the output with `adb logcat -s flutter | grep boot`.
/// Timestamps are relative to the FIRST [mark] -> the engine's pre-`main()` startup is NOT included.
/// Take that slice from logcat's wall-clock column against the `ActivityManager` launch line.
abstract final class BootTrace {
  static final Stopwatch _sw = Stopwatch()..start();

  /// Set by `--dart-define=DIAG=true`, the same switch that restores `debugPrint` in a release
  /// build. It is what makes the REAL build measurable: a profile build reaches `main()` about
  /// three times slower, so any change that hides work behind startup looks better there than it
  /// is, and a profile-vs-profile A/B would flatter it.
  static const _diag = bool.fromEnvironment('DIAG');

  /// Emit `[boot] +1234ms <label>`. No-op in a shipped release; a DIAG release keeps it.
  static void mark(String label) {
    if (kReleaseMode && !_diag) return;
    debugPrint('[boot] +${_sw.elapsedMilliseconds}ms $label');
  }
}
