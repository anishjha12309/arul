import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';

import '../theme/motion.dart';
import '../theme/tokens.dart';
import 'button_content.dart';
import 'button_kind.dart';

export 'button_kind.dart' show ArulButtonKind;

/// The commit affordance. Press is a real spring, not a curve: the overshoot on
/// release is the cheapest cue that a surface is physical rather than a picture
/// of a button. Costs one unbounded controller and zero layout work.
class ArulButton extends StatefulWidget {
  const ArulButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.kind = ArulButtonKind.primary,
    this.icon,
    this.busy = false,
    this.expand = true,
  });

  final String label;
  final VoidCallback? onPressed;
  final ArulButtonKind kind;
  final IconData? icon;
  final bool busy;
  final bool expand;

  @override
  State<ArulButton> createState() => _ArulButtonState();
}

class _ArulButtonState extends State<ArulButton>
    with SingleTickerProviderStateMixin {
  late final _c = AnimationController.unbounded(vsync: this, value: 1);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _springTo(double target) => _c.animateWith(
    SpringSimulation(Motion.press, _c.value, target, _c.velocity),
  );

  bool get _enabled => widget.onPressed != null && !widget.busy;

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = widget.kind.colors(Theme.of(context).colorScheme);

    return Semantics(
      button: true,
      enabled: _enabled,
      label: widget.label,
      child: GestureDetector(
        onTapDown: _enabled ? (_) => _springTo(0.96) : null,
        onTapUp: _enabled ? (_) => _springTo(1) : null,
        onTapCancel: _enabled ? () => _springTo(1) : null,
        onTap: _enabled
            ? () {
                HapticFeedback.lightImpact();
                widget.onPressed!();
              }
            : null,
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, child) =>
              Transform.scale(scale: _c.value, child: child),
          child: Opacity(
            opacity: _enabled ? 1 : 0.5,
            child: Container(
              width: widget.expand ? double.infinity : null,
              height: 54,
              padding: const EdgeInsets.symmetric(horizontal: Gap.xl),
              decoration: BoxDecoration(
                color: bg,
                borderRadius: Radii.buttonShape,
              ),
              child: ButtonContent(
                label: widget.label,
                icon: widget.icon,
                busy: widget.busy,
                foreground: fg,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
