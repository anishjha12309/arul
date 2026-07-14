import 'package:flutter/material.dart';

import 'tokens.dart';

/// Gradient scrims — how chrome stays legible over an arbitrary wallpaper.
///
/// This is deliberately NOT glassmorphism. `BackdropFilter` costs roughly 6-9ms
/// of raster per frame at a usable sigma on mid-tier Android; on the budget SoCs
/// this app targets that alone would blow the 16ms budget the video decoder
/// already competes for. `ShaderMask` and anything that forces `saveLayer()` are
/// out for the same reason: they buy an offscreen pass per frame, per widget. A
/// gradient is an ordinary paint — no offscreen buffer, no measurable cost — and
/// over full-bleed photography it reads richer than blur anyway. (It is also what
/// the big video feeds actually ship.)
///
/// ── How these stops were chosen ──────────────────────────────────────────────
/// The ground under a scrim is NOT ours: it is whatever wallpaper the user is
/// looking at. So every ramp is tuned against the worst case an image can present
/// — a PURE WHITE frame — and the guarantee is stated as the fraction of the
/// scrim's height in which text still clears WCAG. Above that band, chrome must
/// carry its own fill ([ArulColors.mediaFill]); it is not decoration, it is the
/// difference between 2.2:1 and 4.19:1 for the gold Apply ring.
///
/// Both ramps fade black→transparent (`Color(0x00000000)` is transparent BLACK,
/// so only alpha moves and no grey fringe appears mid-ramp), and both use four or
/// five stops rather than two. A straight two-stop ramp puts a visible banding
/// edge where the tail meets the image; the low-alpha stop near the end flattens
/// it out for free.
abstract final class ArulScrims {
  /// Behind top chrome (the feed chip row). README: feed top scrim, h130,
  /// `.62 → 0`, tinted the dark surface `#14090C` (== rgba(20,9,12,x)). The
  /// low-alpha mid-stop is the anti-banding tail.
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

  /// Behind bottom chrome (meta + action rail). README: feed bottom scrim, h190,
  /// `.72 → 0`. Stronger than [top] because this is where the text lives; chrome
  /// that reaches above the guaranteed band carries its own [ArulColors.mediaFill].
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

  /// Silk: the premium ground for the KolamBackground painter. Maroon into the
  /// dark surface, off-axis so it reads as woven cloth rather than a flat ramp.
  ///
  /// This is the OPAQUE brand ground used by the painter. The translucent silk
  /// card gradients from the README (profile/hero/plan cards) live in
  /// [ArulTokens.silkDark] / [ArulTokens.silkLight].
  static const silk = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [ArulColors.roseDeep, ArulColors.roseInk, ArulColors.ink],
    stops: [0.0, 0.42, 1.0],
  );

  /// Zari: the thin gold edge that makes a card look bordered rather than
  /// stuck-on. Used as a 1px stroke, never a fill.
  static const zari = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [ArulColors.goldSoft, ArulColors.gold, Color(0x00D4A017)],
    stops: [0.0, 0.35, 1.0],
  );
}
