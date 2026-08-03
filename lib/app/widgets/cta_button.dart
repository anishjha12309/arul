import 'package:flutter/material.dart';

import '../../core/haptics/arul_haptics.dart';
import '../../theme/arul_tokens.dart';

/// The green primary CTA — spec: "ctaGreen `#1FA75A` — ALL primary CTAs".
///
/// Fully-rounded (r999), green fill, darkening to [ArulTokens.ctaGreenHover] on
/// press, white 15–16px/600 label with an optional leading icon. Feedback is
/// transform + opacity ONLY (spec motion rule): a slight scale-down and the
/// colour swap, no shadow, no blur.
class CtaButton extends StatefulWidget {
  const CtaButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.height = ArulTokens.ctaHeight52,
    this.icon,
    this.fontSize = 15,
    this.expand = true,
    this.busy = false,
    this.haptic = ArulHapticStyle.tap,
  });

  final String label;
  final VoidCallback? onPressed;

  /// The impulse fired as the finger lands. [ArulHapticStyle.firm] suits the
  /// committing presses (start premium, apply); [ArulHapticStyle.none] where an
  /// outcome toast already carries the beat.
  final ArulHapticStyle haptic;

  /// One of 50 / 52 / 54 per the design (spec: "primary 50–54px"). Defaults to
  /// [ArulTokens.ctaHeight52].
  final double height;

  final IconData? icon;

  /// Spec button label is 15–16px; default 15, pass 16 where the site calls it.
  final double fontSize;

  final bool expand;
  final bool busy;

  @override
  State<CtaButton> createState() => _CtaButtonState();
}

class _CtaButtonState extends State<CtaButton> {
  bool _pressed = false;

  bool get _enabled => widget.onPressed != null && !widget.busy;

  @override
  Widget build(BuildContext context) {
    final bg = _pressed ? ArulTokens.ctaGreenHover : ArulTokens.ctaGreen;

    Widget wrapIntrinsic(Widget w) =>
        widget.expand ? w : IntrinsicWidth(child: w);

    final child = widget.busy
        ? const SizedBox.square(
            dimension: 22,
            child: CircularProgressIndicator(
              strokeWidth: 2.4,
              color: Colors.white,
            ),
          )
        : Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.icon != null) ...[
                Icon(widget.icon, size: 20, color: Colors.white),
                const SizedBox(width: 8),
              ],
              Flexible(
                child: Text(
                  widget.label,
                  overflow: TextOverflow.ellipsis,
                  style: ArulTokens.button.copyWith(
                    fontSize: widget.fontSize,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          );

    return Semantics(
      button: true,
      enabled: _enabled,
      label: widget.label,
      child: GestureDetector(
        // Press-DOWN, in step with the scale dip and the colour swap.
        onTapDown: _enabled
            ? (_) {
                ArulHaptics.fire(widget.haptic);
                setState(() => _pressed = true);
              }
            : null,
        onTapUp: _enabled ? (_) => setState(() => _pressed = false) : null,
        onTapCancel: _enabled ? () => setState(() => _pressed = false) : null,
        onTap: _enabled ? widget.onPressed : null,
        child: AnimatedScale(
          scale: _pressed ? 0.97 : 1,
          duration: const Duration(milliseconds: 90),
          child: Opacity(
            opacity: _enabled ? 1 : 0.5,
            // A Container with a non-null alignment fills bounded constraints
            // even with width null, so a compact pill (expand: false) must be
            // forced back to its intrinsic width.
            child: wrapIntrinsic(
              Container(
                width: widget.expand ? double.infinity : null,
                height: widget.height,
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(
                  horizontal: ArulTokens.cardPadding20,
                ),
                decoration: BoxDecoration(
                  color: bg,
                  borderRadius: BorderRadius.circular(ArulTokens.pillRadius),
                ),
                child: child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
