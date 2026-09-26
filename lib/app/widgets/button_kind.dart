import 'package:flutter/material.dart';

import '../../theme/arul_tokens.dart';
import '../theme/tokens.dart';

enum ArulButtonKind {
  /// The commit action, green -> maroon and gold compete with the brand chrome -> neither reads "go".
  primary,

  gold,

  quiet,
}

extension ArulButtonPalette on ArulButtonKind {
  (Color, Color) colors(ColorScheme scheme) => switch (this) {
    ArulButtonKind.primary => (ArulColors.cta, ArulTokens.onCta),
    ArulButtonKind.gold => (ArulColors.gold, ArulColors.ink),
    ArulButtonKind.quiet => (
      scheme.onSurface.withValues(alpha: 0.08),
      scheme.onSurface,
    ),
  };
}
