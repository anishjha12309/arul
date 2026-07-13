import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// A small pill label over media (category name, LIVE badge).
///
/// It carries its own translucent ink fill + hairline border so it stays legible
/// on ANY wallpaper underneath — a plain text label cannot.
class PillTag extends StatelessWidget {
  const PillTag({super.key, required this.label, this.gold = false});

  final String label;
  final bool gold;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: 5),
      decoration: BoxDecoration(
        color: gold ? ArulColors.gold : Colors.black.withValues(alpha: 0.42),
        borderRadius: const BorderRadius.all(Radius.circular(Radii.chip)),
        border: Border.all(
          color: gold
              ? ArulColors.gold
              : Colors.white.withValues(alpha: 0.24),
        ),
      ),
      child: Text(
        label.toUpperCase(),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: gold ? ArulColors.ink : Colors.white,
        ),
      ),
    );
  }
}
