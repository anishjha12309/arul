import 'package:flutter/material.dart';

import '../../../theme/arul_tokens.dart';

/// The live-wallpaper marker: a play triangle held in a small glass disc.
///
/// NEVER text (owner's call) -> the gold `LIVE` pill it replaced read as a warning on half the
/// catalog and shipped untranslated English in a six-language app; a glyph has nothing to localize.
///
/// **The Share circle at half scale, with ONE deliberate difference.** Same
/// [ArulTokens.overMediaGlassBorder] hairline, but SMOKED [ArulTokens.overMediaInkFill] where Share
/// is frosted [ArulTokens.overMediaGlassFill] -> not drift; the two sit in different light.
/// Share lives inside the bottom scrim, so a dark ground is guaranteed -> it can be the bright half.
/// This mark sits on raw artwork and a third of the catalog is white marble -> ivory-on-white is
/// invisible at any alpha -> the disc is the dark half and the ivory is kept for glyph and rim.
///
/// **No shadow** (owner's call) -> the rail glyphs' two-layer halo read as a black smudge over the
/// artwork on EVERY wallpaper -> contrast belongs INSIDE the disc; do not re-add one.
///
/// Static — no controller, no ticker, no repaint boundary -> it shares a card with a live `Texture`
/// and the cheapest mark is one that never asks for a frame.
///
/// It marks live-ness PERMANENTLY, not loading -> an undecoded live card is pixel-identical to a
/// static one (`ViewerMedia` keeps a poster under the texture), so this is the only thing telling
/// them apart; it stays once the clip plays — "will this move?" holds on a paused neighbour too.
class LiveMark extends StatelessWidget {
  const LiveMark({super.key});

  /// Outer diameter — under half the Share circle's 52: the same object, said quietly. Big enough
  /// that the triangle survives at arm's length, small enough never to compete with the artwork.
  static const double diameter = 24;

  /// The play triangle — 14 in a 24 disc leaves a ring of glass, not a glyph straining at the edge.
  static const double glyphSize = 14;

  @override
  Widget build(BuildContext context) {
    return const SizedBox.square(
      dimension: diameter,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: ArulTokens.overMediaInkFill,
          shape: BoxShape.circle,
          border: Border.fromBorderSide(
            BorderSide(color: ArulTokens.overMediaGlassBorder),
          ),
        ),
        // An Icon lays itself out at its own size inside the parent's constraints -> without this
        // Center it hangs off the disc's top-left.
        child: Center(
          child: Icon(
            Icons.play_arrow_rounded,
            size: glyphSize,
            color: ArulTokens.ivory,
          ),
        ),
      ),
    );
  }
}
