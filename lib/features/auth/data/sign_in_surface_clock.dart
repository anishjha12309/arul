import 'package:flutter/widgets.dart';

/// How long Google's own surface took to appear, per attempt.
///
/// There is no callback for "the Credential Manager sheet is now on screen" — the sheet and the
/// picker are GMS activities drawn OVER ours, so the only signal the app gets is its own lifecycle
/// going inactive/paused/hidden. The stall guard already treats that as "a Google surface is up,
/// extend" (auth_providers.dart `_guard`); this reads the same edge for its TIME.
///
/// First edge only, and reset per attempt: a user who leaves the picker, takes a call and comes
/// back must not have the call counted as Google being slow.
abstract interface class SignInSurfaceClock {
  /// Arms a fresh measurement. Called immediately before the attempt's first Google surface.
  /// [onSurface] fires once, when the first inactive/paused/hidden lands during the attempt.
  void startAttempt({void Function(int msToSurface)? onSurface});

  /// Disarms and DROPS the reading -> the next attempt can never report the last one's wait.
  /// Every read happens while the attempt is still live, so clearing here costs nothing.
  /// Safe to call twice, and safe on an attempt that never started.
  void endAttempt();

  /// Milliseconds from [startAttempt] to the first inactive/paused/hidden, or null when the app
  /// never left the foreground -> no Google surface was ever seen.
  int? get msToSurface;
}

/// The shipping clock: one [WidgetsBindingObserver], registered only while an attempt is live.
///
/// Registered late and removed on completion so a signed-in process carries no observer, and so a
/// backgrounding that has nothing to do with sign-in is never timed.
class BindingSignInSurfaceClock
    with WidgetsBindingObserver
    implements SignInSurfaceClock {
  Stopwatch? _clock;
  bool _observing = false;
  int? _msToSurface;

  @override
  int? get msToSurface => _msToSurface;

  void Function(int msToSurface)? _onSurface;

  @override
  void startAttempt({void Function(int msToSurface)? onSurface}) {
    _msToSurface = null;
    _onSurface = onSurface;
    _clock = Stopwatch()..start();
    if (!_observing) {
      WidgetsBinding.instance.addObserver(this);
      _observing = true;
    }
  }

  @override
  void endAttempt() {
    _clock = null;
    _msToSurface = null;
    if (_observing) {
      WidgetsBinding.instance.removeObserver(this);
      _observing = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_msToSurface != null) return;
    final clock = _clock;
    if (clock == null) return;
    switch (state) {
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        final ms = clock.elapsedMilliseconds;
        _msToSurface = ms;
        // Fired ONCE per attempt, the first time something covers us: the only proof the app has
        // that Google's screen actually appeared for people who then vanish without an outcome.
        _onSurface?.call(ms);
      case AppLifecycleState.resumed:
      case AppLifecycleState.detached:
        break;
    }
  }
}
