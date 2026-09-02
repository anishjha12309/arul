import 'package:flutter/material.dart';

import 'tokens.dart';

/// Gradient scrims — how chrome stays legible over an arbitrary wallpaper.
///
/// NOT glassmorphism: `BackdropFilter` costs ~6-9ms of raster per frame at a usable sigma on mid-tier
/// Android -> on a budget SoC that alone blows the 16ms budget the video decoder already competes for.
/// `ShaderMask` and anything forcing `saveLayer()` are out for the same reason — an offscreen pass per
/// frame, per widget.
/// A gradient is ordinary paint -> no offscreen buffer, no measurable cost -> and over full-bleed
/// photography it reads richer than blur anyway (it is what the big video feeds ship).
///
/// The ground under a scrim is NOT ours -> tune every ramp against the worst case an image can show,
/// a PURE WHITE frame -> the guarantee is the fraction of the scrim's height where text clears WCAG.
/// Above that band chrome carries its own fill ([ArulColors.mediaFill]) -> not decoration: it is
/// 2.2:1 versus 4.19:1 for the gold Apply ring.
/// `Color(0x00000000)` is transparent BLACK -> only alpha moves -> no grey fringe mid-ramp.
/// A straight two-stop ramp bands visibly where the tail meets the image -> a third, low-alpha stop
/// near the end flattens it out for free.
abstract final class ArulScrims {
  /// Behind top chrome (the feed chip row) — spec: h130, `.62 → 0`, tinted the dark surface `#14090C`.
  /// The low-alpha mid-stop is the anti-banding tail.
  static const top = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [
      Color(0x9E14090C), // 62%
      Color(0x2E14090C), // 18% — the anti-banding tail
      Color(0x0014090C),
    ],
    stops: [0.0, 0.6, 1.0],
  );

  /// Behind bottom chrome (meta + action rail) — spec: h190, `.72 → 0`.
  /// The text lives here -> stronger than [top] -> chrome reaching above the guaranteed band still
  /// carries its own [ArulColors.mediaFill].
  static const bottom = LinearGradient(
    begin: Alignment.bottomCenter,
    end: Alignment.topCenter,
    colors: [
      Color(0xB814090C), // 72%
      Color(0x3D14090C), // 24% — the anti-banding tail
      Color(0x0014090C),
    ],
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
