import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// Label / icon / busy-spinner interior of [ArulButton]. Split out so the
/// button file stays about the press physics.
class ButtonContent extends StatelessWidget {
  const ButtonContent({
    super.key,
    required this.label,
    required this.foreground,
    this.icon,
    this.busy = false,
  });

  final String label;
  final Color foreground;
  final IconData? icon;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    if (busy) {
      return Center(
        child: SizedBox.square(
          dimension: 22,
          child: CircularProgressIndicator(strokeWidth: 2.4, color: foreground),
        ),
      );
    }
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 20, color: foreground),
          const SizedBox(width: Gap.sm),
        ],
        Flexible(
          child: Text(
            label,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.labelLarge?.copyWith(color: foreground),
          ),
        ),
      ],
    );
  }
}
