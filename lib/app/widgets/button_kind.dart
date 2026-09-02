import 'package:flutter/material.dart';

import '../theme/tokens.dart';

enum ArulButtonKind {
  /// The commit action, green -> maroon and gold compete with the brand chrome -> neither reads "go".
  primary,

  /// Brand action on a dark/silk surface (sign-in, unlock).
  gold,

  /// Secondary. Present but not shouting.
  quiet,
}

extension ArulButtonPalette on ArulButtonKind {
  /// (background, foreground) for this kind.
  (Color, Color) colors(ColorScheme scheme) => switch (this) {
    ArulButtonKind.primary => (ArulColors.cta, Colors.white),
    ArulButtonKind.gold => (ArulColors.gold, ArulColors.ink),
    ArulButtonKind.quiet => (
      scheme.onSurface.withValues(alpha: 0.08),
      scheme.onSurface,
    ),
  };
}
