import 'package:flutter/material.dart';

import '../../core/haptics/arul_haptics.dart';
import '../../theme/arul_tokens.dart';
import '../theme/motion.dart';

/// An icon-only tappable, built the way every icon control here should be.
///
/// A [ArulTokens.minHitTarget] box around the glyph (the glyph itself never grows), a name for
/// TalkBack, the tap haptic on press-DOWN and a dip while pressed. Material's `IconButton` brings a
/// ripple and its own splash palette; this one paints nothing but the glyph, so it sits on a silk
/// card or a header without a foreign circle appearing under the finger.
///
/// The box is [ArulTokens.minHitTarget] on both sides, so a caller that used to give a bare glyph a
/// gap writes `gap - slack`, where `slack = (minHitTarget - size) / 2` — the glyph then lands
/// exactly where it did.
class ArulIconTap extends StatefulWidget {
  const ArulIconTap({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.size = 24,
    this.color,
    this.haptic = ArulHapticStyle.tap,
    this.identifier,
  });

  final IconData icon;

  /// What TalkBack says — the action, never the glyph's name.
  final String label;

  final VoidCallback? onTap;
  final double size;
  final Color? color;
  final ArulHapticStyle haptic;

  /// Stable accessibility id (`Semantics(identifier:)`): announced to nobody, so it is free at
  /// the UI layer and survives every locale.
  final String? identifier;

  /// The transparent hit area either side of a glyph of [size].
  static double slackFor(double size) => (ArulTokens.minHitTarget - size) / 2;

  @override
  State<ArulIconTap> createState() => _ArulIconTapState();
}

class _ArulIconTapState extends State<ArulIconTap> {
  bool _pressed = false;

  bool get _enabled => widget.onTap != null;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: _enabled,
      label: widget.label,
      identifier: widget.identifier,
      // The glyph would otherwise be announced a second time, nameless.
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: _enabled
            ? (_) {
                ArulHaptics.fire(widget.haptic);
                setState(() => _pressed = true);
              }
            : null,
        onTapUp: _enabled ? (_) => setState(() => _pressed = false) : null,
        onTapCancel: _enabled ? () => setState(() => _pressed = false) : null,
        onTap: widget.onTap,
        child: SizedBox.square(
          dimension: ArulTokens.minHitTarget,
          child: Center(
            child: AnimatedOpacity(
              // Holds at full opacity when motion is reduced; the haptic still answers.
              opacity: _pressed && !context.reduceMotion ? 0.55 : 1,
              duration: context.reduceMotion ? Duration.zero : Motion.pressDip,
              child: Icon(widget.icon, size: widget.size, color: widget.color),
            ),
          ),
        ),
      ),
    );
  }
}
