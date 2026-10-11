import 'package:flutter/material.dart';

import '../../core/haptics/arul_haptics.dart';
import '../../theme/arul_palette.dart';
import '../../theme/arul_tokens.dart';
import '../theme/motion.dart';
import 'arul_line_icons.dart';

/// One option of an [ArulSegmented].
class ArulSegment<T> {
  const ArulSegment({
    required this.value,
    required this.label,
    required this.glyph,
    this.identifier,
  });

  final T value;
  final String label;

  /// The dock's own glyph for the same thing, so the two never describe it differently.
  final ArulLineGlyph glyph;

  final String? identifier;
}

/// A pill track of equal segments with a sliding thumb — for switching a MODE. Chips there read
/// as one more value among the choices under them, which is what made the upload form look flat.
/// Selected is the chips' own accent: gold on dark, maroon on light.
class ArulSegmented<T> extends StatelessWidget {
  const ArulSegmented({
    super.key,
    required this.segments,
    required this.selected,
    required this.onChanged,
  });

  final List<ArulSegment<T>> segments;
  final T selected;
  final ValueChanged<T> onChanged;

  static const double _inset = ArulSpace.s4;

  /// A segment is the full hit target; the track adds its inset around it.
  static const double height = ArulTokens.minHitTarget + 2 * _inset;

  @override
  Widget build(BuildContext context) {
    final p = ArulPalette.of(context);
    final n = segments.length;
    final index = segments.indexWhere((s) => s.value == selected);
    final at = index < 0 ? 0 : index;
    return Container(
      height: height,
      padding: const EdgeInsets.all(_inset),
      decoration: BoxDecoration(
        color: p.field,
        borderRadius: BorderRadius.circular(ArulTokens.pillRadius),
        border: Border.all(color: p.border),
      ),
      child: Stack(
        children: [
          AnimatedAlign(
            alignment: Alignment(n < 2 ? 0 : -1 + 2 * at / (n - 1), 0),
            duration: context.reduceMotion ? Duration.zero : Motion.settle,
            curve: Motion.settleCurve,
            child: FractionallySizedBox(
              widthFactor: 1 / n,
              heightFactor: 1,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: p.accent,
                  borderRadius: BorderRadius.circular(ArulTokens.pillRadius),
                ),
              ),
            ),
          ),
          Row(
            children: [
              for (final s in segments)
                Expanded(
                  child: _SegmentButton<T>(
                    segment: s,
                    selected: s.value == selected,
                    onTap: () => onChanged(s.value),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SegmentButton<T> extends StatelessWidget {
  const _SegmentButton({
    required this.segment,
    required this.selected,
    required this.onTap,
  });

  final ArulSegment<T> segment;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = ArulPalette.of(context);
    final ink = selected ? p.onAccent : p.textSecondary;
    return Semantics(
      container: true,
      button: true,
      selected: selected,
      label: segment.label,
      identifier: segment.identifier,
      onTap: onTap,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => ArulHaptics.selection(),
        onTap: onTap,
        child: Center(
          // A long label at a large text size shrinks in place instead of wrapping the track.
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: ArulSpace.s8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ArulLineIcon(glyph: segment.glyph, size: 18, color: ink),
                  const SizedBox(width: 6),
                  Text(
                    segment.label,
                    maxLines: 1,
                    style: (selected ? ArulTokens.chipActive : ArulTokens.chip)
                        .copyWith(color: ink),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
