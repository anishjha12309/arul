import 'package:flutter/material.dart';

import '../../core/haptics/arul_haptics.dart';
import '../../theme/arul_tokens.dart';

/// The green primary CTA — `ctaGreen` is the fill for ALL primary CTAs.
///
/// Press feedback is transform + opacity ONLY (the spec's motion rule) -> a scale dip and the colour
/// swap, never a shadow or a blur.
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

  /// The impulse fired as the finger lands -> [ArulHapticStyle.firm] for committing presses (start
  /// premium, apply), [ArulHapticStyle.none] where an outcome toast already carries the beat.
  final ArulHapticStyle haptic;

  /// One of 50 / 52 / 54 — the design's primary range.
  final double height;

  final IconData? icon;

  /// The spec's label size is 15–16px -> pass 16 only where the call site asks for it.
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
        // The haptic rides press-DOWN -> it lands in step with the scale dip and the colour swap.
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
            // A Container with a non-null alignment fills bounded constraints even at width null ->
            // force a compact pill (expand: false) back to its intrinsic width.
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
