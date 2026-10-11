import 'package:flutter/material.dart';

import '../../core/haptics/arul_haptics.dart';
import '../theme/motion.dart';

/// A tappable that answers on press-DOWN: the haptic beat, a small dip in scale, and a `pressed`
/// flag its [builder] can tint with. The scale is a transform, so it costs no layout and no layer.
class ArulPressable extends StatefulWidget {
  const ArulPressable({
    super.key,
    required this.builder,
    required this.onTap,
    this.haptic = ArulHapticStyle.tap,
    this.pressedScale = 0.98,
    this.semanticLabel,
    this.identifier,
    this.selected,
  });

  final Widget Function(BuildContext context, bool pressed) builder;
  final VoidCallback? onTap;
  final ArulHapticStyle haptic;

  /// 0.98 for a card or a row; a small control dips further (0.97, the CTA's).
  final double pressedScale;

  /// Read as the button's whole label. Null leaves the child's own semantics in place.
  final String? semanticLabel;
  final String? identifier;
  final bool? selected;

  @override
  State<ArulPressable> createState() => _ArulPressableState();
}

class _ArulPressableState extends State<ArulPressable> {
  bool _pressed = false;

  void _set(bool pressed) {
    if (_pressed != pressed) setState(() => _pressed = pressed);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    final still = context.reduceMotion;
    return Semantics(
      container: true,
      button: true,
      // Only a disabled control announces a state; an enabled one needs none.
      enabled: enabled ? null : false,
      selected: widget.selected,
      label: widget.semanticLabel,
      identifier: widget.identifier,
      onTap: widget.onTap,
      excludeSemantics: widget.semanticLabel != null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: enabled
            ? (_) {
                ArulHaptics.fire(widget.haptic);
                _set(true);
              }
            : null,
        onTapUp: enabled ? (_) => _set(false) : null,
        onTapCancel: enabled ? () => _set(false) : null,
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _pressed && !still ? widget.pressedScale : 1,
          duration: still ? Duration.zero : Motion.pressDip,
          curve: Motion.quickCurve,
          child: widget.builder(context, _pressed),
        ),
      ),
    );
  }
}
