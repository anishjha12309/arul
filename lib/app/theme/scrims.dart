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
  /// Behind top chrome. Roughly 96–120dp tall in use.
  ///
  /// Guarantee: white clears 4.5:1 over a pure-white frame down to t=0.38.
  /// The status bar — the only chrome up here with no fill of its own — sits at
  /// t≤0.25, where it measures 6.88:1. The back button lives lower but carries
  /// [ArulColors.mediaFill], so it does not depend on the ramp.
  static const top = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [
      Color(0xCF000000), // 81%
      Color(0x94000000), // 58%
      Color(0x2B000000), // 17% — the anti-banding tail
      Color(0x00000000),
    ],
    stops: [0.0, 0.35, 0.68, 1.0],
  );

  /// Behind bottom chrome (eyebrow + title + the action rail). ~200dp in use, and
  /// taller and stronger than [top] because this is where the text lives.
  ///
  /// Guarantees over a pure-white frame, measured:
  ///   white body text                ≥4.5:1 up to t=0.57
  ///   ArulType.onMedia() muted tier   ≥4.5:1 up to t=0.52
  ///   gold (UI/large, 3:1)            ≥3.0:1 up to t=0.45
  /// The metadata block occupies roughly the bottom 90dp of 200dp — t≤0.45 — so
  /// it sits inside all three bands with headroom (white 8.1:1, muted 6.4:1).
  /// The action rail reaches higher than that, which is exactly why its buttons
  /// carry their own fill.
  static const bottom = LinearGradient(
    begin: Alignment.bottomCenter,
    end: Alignment.topCenter,
    colors: [
      Color(0xE6000000), // 90%
      Color(0xBF000000), // 75%
      Color(0x73000000), // 45%
      Color(0x24000000), // 14% — the anti-banding tail
      Color(0x00000000),
    ],
    stops: [0.0, 0.40, 0.64, 0.84, 1.0],
  );

  /// Silk: the premium surface. Lotus rose into ink, off-axis so it reads as woven
  /// cloth rather than a flat vertical ramp.
  ///
  /// The rose head is held to the top ~42% on purpose. The premium CTA is a FILLED
  /// button ([ArulColors.tealCta]) and it lands near the bottom of this diagonal
  /// (t≈0.72–0.85), where it clears 3:1 against the ramp (3.08–3.38:1). Against
  /// the rose head it would be 1.83:1. Do not move a filled control into the top
  /// half of silk — white TEXT is fine anywhere on it (9.4:1 at the worst stop).
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
    colors: [ArulColors.goldSoft, ArulColors.gold, Color(0x00C29B4E)],
    stops: [0.0, 0.35, 1.0],
  );
}
