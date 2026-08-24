import 'package:flutter/foundation.dart';

/// Cold-start / sign-in latency trace.
///
/// Answers one question the Firebase Performance traces cannot: on a
/// from-scratch launch, where do the seconds between tapping the icon and the
/// Google account sheet actually go? The path crosses four layers (engine →
/// `main()` → the splash's auth-seed wait → the sign-in route → Credential
/// Manager), and only a single monotonic clock spanning all of them shows
/// which one owns the delay.
///
/// Compiled out of release builds entirely — [mark] is a no-op there, and the
/// call sites are cheap enough that they cost nothing to leave in place. Read
/// the output with:
///
/// ```
/// adb logcat -s flutter | grep boot
/// ```
///
/// Timestamps are relative to the first [mark] (the top of `main()`), so the
/// engine's own pre-`main()` startup is NOT included — take that slice from
/// logcat's own wall-clock column against the `ActivityManager` launch line.
abstract final class BootTrace {
  static final Stopwatch _sw = Stopwatch()..start();

  /// Emit `[boot] +1234ms <label>`. No-op in release.
  static void mark(String label) {
    if (kReleaseMode) return;
    debugPrint('[boot] +${_sw.elapsedMilliseconds}ms $label');
  }
}
