import 'package:flutter/material.dart';

import '../../theme/arul_tokens.dart';

enum ArulButtonKind {
  /// The commit action, green -> maroon and gold compete with the brand chrome -> neither reads "go".
  primary,

  gold,

  quiet,
}

extension ArulButtonPalette on ArulButtonKind {
  (Color, Color) colors(ColorScheme scheme) => switch (this) {
    ArulButtonKind.primary => (ArulTokens.ctaGreen, ArulTokens.onCta),
    ArulButtonKind.gold => (ArulTokens.gold, ArulTokens.darkSurface),
    ArulButtonKind.quiet => (
      scheme.onSurface.withValues(alpha: 0.08),
      scheme.onSurface,
    ),
  };
}
