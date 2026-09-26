import 'dart:async';

import 'package:flutter/services.dart';

/// How firmly a control answers a touch.
///
/// These map onto Flutter's primitives, which the Android embedder resolves to `performHapticFeedback`:
///
/// | style       | Flutter            | Android            |
/// | ----------- | ------------------ | ------------------ |
/// | [selection] | `selectionClick()` | `CLOCK_TICK`       |
/// | [tap]       | `lightImpact()`    | `VIRTUAL_KEY`      |
/// | [firm]      | `mediumImpact()`   | `KEYBOARD_TAP`     |
/// | [heavy]     | `heavyImpact()`    | `CONTEXT_CLICK`    |
enum ArulHapticStyle {
  /// No haptic — for controls that fire repeatedly, or where the outcome already carries one.
  none,

  /// The lightest tick — moving between discrete values: tabs, chips, radios, toggles.
  selection,

  tap,

  /// A weightier press for a deliberate, committing action.
  firm,

  /// The strongest single beat — destructive confirmations and outcome cues.
  heavy,
}

/// The app's haptic vocabulary. Ported from Pakiza's `PkHaptics` — shared behaviour, keep in step.
///
/// 1. **One haptic per beat.** A press fires exactly one; the *outcome* fires exactly one more.
///    Nothing in between — sheet opens and route pushes are silent, the tap already answered.
/// 2. **Press-down, not release.** Controls fire as the finger lands, in step with the press dip.
///
/// A reel that buzzed on every flick would fire dozens of times a minute -> swipes get NO haptic.
/// Every call is fire-and-forget and swallows platform errors -> no vibrator, no channel, no throw.
/// Android's `performHapticFeedback` already honours the system-wide touch-feedback setting.
/// [setEnabled] is an in-app preference layered on top of that.
abstract final class ArulHaptics {
  const ArulHaptics._();

  static bool _enabled = true;

  static bool get enabled => _enabled;

  static void setEnabled(bool value) => _enabled = value;

  static void selection() => _impulse(HapticFeedback.selectionClick);

  static void tap() => _impulse(HapticFeedback.lightImpact);

  static void firm() => _impulse(HapticFeedback.mediumImpact);

  static void heavy() => _impulse(HapticFeedback.heavyImpact);

  static void fire(ArulHapticStyle style) => switch (style) {
    ArulHapticStyle.none => null,
    ArulHapticStyle.selection => selection(),
    ArulHapticStyle.tap => tap(),
    ArulHapticStyle.firm => firm(),
    ArulHapticStyle.heavy => heavy(),
  };

  /// It worked — a rising two-beat (light → medium): applied, shared, subscribed.
  static void success() {
    if (!_enabled) return;
    _impulse(HapticFeedback.lightImpact);
    _after(90, HapticFeedback.mediumImpact);
  }

  /// It failed — a double thud, heavier and slower than [success] so the two differ without looking.
  static void error() {
    if (!_enabled) return;
    _impulse(HapticFeedback.heavyImpact);
    _after(130, HapticFeedback.heavyImpact);
  }

  static void warning() => firm();

  static void _impulse(Future<void> Function() feedback) {
    if (!_enabled) return;
    // Never let a missing vibrator or platform channel surface as an unhandled async error.
    unawaited(feedback().catchError((_) {}));
  }

  static void _after(int ms, Future<void> Function() feedback) {
    Timer(Duration(milliseconds: ms), () => _impulse(feedback));
  }
}
