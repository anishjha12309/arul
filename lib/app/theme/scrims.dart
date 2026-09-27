import 'package:flutter/material.dart';

import 'tokens.dart';

/// The ground under a scrim is NOT ours -> tune every ramp against the worst case an image can show,
/// a PURE WHITE frame -> the guarantee is the fraction of the scrim's height where text clears WCAG.
/// A straight two-stop ramp bands visibly where the tail meets the image -> a third, low-alpha stop
/// near the end flattens it out for free.
abstract final class ArulScrims {
  /// Behind top chrome (the feed chip row) — spec: h130, `.62 → 0`, tinted the dark surface `#14090C`.
  /// The low-alpha mid-stop is the anti-banding tail.
  static const top = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0x9E14090C), Color(0x2E14090C), Color(0x0014090C)],
    stops: [0.0, 0.6, 1.0],
  );

  /// Behind bottom chrome (meta + action rail) — spec: h190, `.72 → 0`.
  /// The text lives here -> stronger than [top] -> chrome reaching above the guaranteed band still
  /// carries its own [ArulColors.mediaFill].
  static const bottom = LinearGradient(
    begin: Alignment.bottomCenter,
    end: Alignment.topCenter,
    colors: [Color(0xB814090C), Color(0x3D14090C), Color(0x0014090C)],
    stops: [0.0, 0.55, 1.0],
  );

  /// Silk: the OPAQUE premium ground for the KolamBackground painter.
  /// Maroon into the dark surface, off-axis -> reads as woven cloth, not a flat ramp.
  /// The TRANSLUCENT silk card gradients (profile/hero/plan) live in [ArulTokens.silkDark] /
  /// [ArulTokens.silkLight].
  static const silk = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [ArulColors.roseDeep, ArulColors.roseInk, ArulColors.ink],
    stops: [0.0, 0.42, 1.0],
  );

  /// Zari: the thin gold edge that makes a card read as bordered, not stuck-on -> a 1px stroke,
  /// never a fill.
  static const zari = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [ArulColors.goldSoft, ArulColors.gold, Color(0x00D4A017)],
    stops: [0.0, 0.35, 1.0],
  );
}
