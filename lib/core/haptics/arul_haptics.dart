import 'dart:async';

import 'package:flutter/services.dart';

/// How firmly a control answers a touch.
///
/// These map onto the five primitives Flutter exposes, which the Android
/// embedder resolves to `View.performHapticFeedback` constants:
///
/// | style       | Flutter            | Android            |
/// | ----------- | ------------------ | ------------------ |
/// | [selection] | `selectionClick()` | `CLOCK_TICK`       |
/// | [tap]       | `lightImpact()`    | `VIRTUAL_KEY`      |
/// | [firm]      | `mediumImpact()`   | `KEYBOARD_TAP`     |
/// | [heavy]     | `heavyImpact()`    | `CONTEXT_CLICK`    |
enum ArulHapticStyle {
  /// No haptic — for controls that fire many times in a row, or where the
  /// outcome itself already carries one.
  none,

  /// The lightest tick. Moving between discrete values: tab switches, chips,
  /// radios, toggles.
  selection,

  /// The default button press.
  tap,

  /// A weightier press for a deliberate, committing action.
  firm,

  /// The strongest single beat — destructive confirmations and outcome cues.
  heavy,
}

/// The app's haptic vocabulary. Ported from Pakiza's `PkHaptics` — keep the two
/// in step, since this is shared behaviour rather than an Arul delta.
///
/// Two rules keep this from feeling cheap:
///
/// 1. **One haptic per beat.** A press fires exactly one (from the button or the
///    widget's own handler); the *outcome* fires exactly one more (from
///    `showArulToast` / [success] / [error]). Nothing in between — sheet opens
///    and route pushes are deliberately silent, because the tap that triggered
///    them has already answered the finger.
/// 2. **Press-down, not release.** Controls fire as the finger lands, in step
///    with the press dip, so the phone answers before the animation does.
///
/// The feed's vertical swipe is deliberately NOT in this vocabulary: Pakiza
/// gives page changes no haptic, and a reel that buzzed on every flick would
/// fire this dozens of times a minute.
///
/// Every call is fire-and-forget and swallows platform errors: a device with no
/// vibrator, or a test with no platform channel, must never throw into UI code.
/// Android's `performHapticFeedback` already honours the system-wide touch
/// feedback setting, so a user who has haptics off gets nothing without any
/// extra handling here. [setEnabled] exists on top of that for an in-app
/// preference.
abstract final class ArulHaptics {
  const ArulHaptics._();

  static bool _enabled = true;

  /// Whether haptics are on app-wide.
  static bool get enabled => _enabled;

  /// App-level kill switch, layered over the OS touch-feedback setting.
  static void setEnabled(bool value) => _enabled = value;

  // ─── Primitives ────────────────────────────────────────────────────────────

  /// The lightest tick — a discrete value changed (tab, chip, toggle, radio).
  static void selection() => _impulse(HapticFeedback.selectionClick);

  /// The standard button press.
  static void tap() => _impulse(HapticFeedback.lightImpact);

  /// A weightier press for a deliberate action.
  static void firm() => _impulse(HapticFeedback.mediumImpact);

  /// The strongest single beat.
  static void heavy() => _impulse(HapticFeedback.heavyImpact);

  /// Fires the impulse for [style]; [ArulHapticStyle.none] is a no-op.
  static void fire(ArulHapticStyle style) => switch (style) {
    ArulHapticStyle.none => null,
    ArulHapticStyle.selection => selection(),
    ArulHapticStyle.tap => tap(),
    ArulHapticStyle.firm => firm(),
    ArulHapticStyle.heavy => heavy(),
  };

  // ─── Outcomes ──────────────────────────────────────────────────────────────

  /// It worked — a rising two-beat (light → medium). Wallpaper applied, share
  /// sent, subscription started.
  static void success() {
    if (!_enabled) return;
    _impulse(HapticFeedback.lightImpact);
    _after(90, HapticFeedback.mediumImpact);
  }

  /// It failed — a double thud. Deliberately heavier and slower than [success]
  /// so the two are distinguishable without looking at the screen.
  static void error() {
    if (!_enabled) return;
    _impulse(HapticFeedback.heavyImpact);
    _after(130, HapticFeedback.heavyImpact);
  }

  /// Neutral news — a single medium beat (cancelled payment, info toast).
  static void warning() => firm();

  // ─── Plumbing ──────────────────────────────────────────────────────────────

  static void _impulse(Future<void> Function() feedback) {
    if (!_enabled) return;
    // Never let a missing vibrator / missing platform channel surface as an
    // unhandled async error.
    unawaited(feedback().catchError((_) {}));
  }

  static void _after(int ms, Future<void> Function() feedback) {
    Timer(Duration(milliseconds: ms), () => _impulse(feedback));
  }
}
