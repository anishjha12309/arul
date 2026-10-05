import 'package:flutter/material.dart';

import '../../core/haptics/arul_haptics.dart';
import '../../theme/arul_tokens.dart';
import '../theme/motion.dart';
import 'arul_line_icons.dart';

/// A [ArulTokens.minHitTarget] box around the glyph (the glyph itself never grows), a name for
/// TalkBack, the tap haptic on press-DOWN and a dip while pressed. Material's `IconButton` brings a
/// ripple and its own splash palette; this one paints nothing but the glyph, so it sits on a silk
/// card or a header without a foreign circle appearing under the finger.
class ArulIconTap extends StatefulWidget {
  const ArulIconTap({
    super.key,
    required IconData this.icon,
    required this.label,
    required this.onTap,
    this.size = 24,
    this.color,
    this.haptic = ArulHapticStyle.tap,
    this.identifier,
  }) : glyph = null;

  /// A header action: [glyph] inside a tinted round chip that fills the header's control box.
  const ArulIconTap.glyph({
    super.key,
    required ArulLineGlyph this.glyph,
    required this.label,
    required this.onTap,
    this.color,
    this.haptic = ArulHapticStyle.tap,
    this.identifier,
  }) : icon = null,
       size = _headerGlyphSize;

  /// Smaller than the dock's 22 so the glyph has air inside its 34 chip.
  static const double _headerGlyphSize = 20;

  final IconData? icon;
  final ArulLineGlyph? glyph;

  /// What TalkBack says — the action, never the glyph's name.
  final String label;

  final VoidCallback? onTap;
  final double size;
  final Color? color;
  final ArulHapticStyle haptic;

  /// Stable accessibility id (`Semantics(identifier:)`): announced to nobody, so it is free at
  /// the UI layer and survives every locale.
  final String? identifier;

  static double slackFor(double size) => (ArulTokens.minHitTarget - size) / 2;

  /// How far a header glyph's 48 target reaches past its drawn 34 box on each side. The header
  /// LAYS this out into the gutter (`ArulScreenHeader`), so the drawn box stays flush with it.
  static const double headerSpill =
      (ArulTokens.minHitTarget - ArulTokens.headerControlSize) / 2;

  /// The header band's air above and below its control box (`ArulScreenHeader.bandPadding`).
  static const EdgeInsets _headerBand = EdgeInsets.only(
    top: ArulTokens.headerTopPadding,
    bottom: ArulTokens.headerBottomPadding,
  );

  @override
  State<ArulIconTap> createState() => _ArulIconTapState();
}

class _ArulIconTapState extends State<ArulIconTap> {
  bool _pressed = false;

  bool get _enabled => widget.onTap != null;

  @override
  Widget build(BuildContext context) {
    final glyph = widget.glyph;
    final dip = AnimatedOpacity(
      opacity: _pressed && !context.reduceMotion ? 0.55 : 1,
      duration: context.reduceMotion ? Duration.zero : Motion.pressDip,
      child: glyph == null
          ? Icon(widget.icon, size: widget.size, color: widget.color)
          : ArulLineIcon(
              glyph: glyph,
              size: widget.size,
              color:
                  widget.color ??
                  (Theme.of(context).brightness == Brightness.dark
                      ? ArulTokens.gold
                      : ArulTokens.lightText),
            ),
    );
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final Widget box = glyph == null
        ? Center(child: dip)
        // The band's 48 is the target; the eye sees the 34 control box, on the title's line.
        // The box is a tinted chip, not bare ink: a lone glyph melted into the header's dark.
        : Padding(
            padding: ArulIconTap._headerBand,
            child: Center(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isDark
                      ? ArulTokens.goldTintFill12
                      : ArulTokens.maroonTintFill07,
                  border: Border.all(
                    color: isDark
                        ? ArulTokens.goldBorder35
                        : ArulTokens.maroonBorder18,
                  ),
                ),
                child: SizedBox.square(
                  dimension: ArulTokens.headerControlSize,
                  child: Center(child: dip),
                ),
              ),
            ),
          );
    final tap = Semantics(
      button: true,
      enabled: _enabled,
      label: widget.label,
      identifier: widget.identifier,
      onTap: widget.onTap,
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
        child: SizedBox.square(dimension: ArulTokens.minHitTarget, child: box),
      ),
    );
    return tap;
  }
}
