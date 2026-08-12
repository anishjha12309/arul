import 'package:flutter/material.dart';

import '../../../theme/arul_tokens.dart';

/// The live-wallpaper marker: a play triangle held in a small glass disc.
///
/// Replaces the gold `LIVE` text pill (owner's call, 2026-08-11, chosen from a
/// sheet of ten candidates). The pill read as a warning on roughly half the
/// catalog, and it shipped untranslated English in a six-language app. A glyph
/// has nothing to localize — ever — which is most of why it won.
///
/// **It is the Share circle at half scale, with one deliberate difference.**
/// Same [ArulTokens.overMediaGlassBorder] hairline, but SMOKED glass
/// ([ArulTokens.overMediaInkFill]) where the Share circle is frosted
/// ([ArulTokens.overMediaGlassFill]). That is not drift — the two sit in
/// different light. The Share circle lives inside the bottom scrim, which
/// guarantees a dark ground behind it, so it can afford to be the bright half
/// of the pair. This mark sits at the TOP of the card on raw artwork, where the
/// ground is unknown and a third of the catalog is white marble. Ivory-on-white
/// is invisible at any alpha, so here the disc is the dark half and the ivory
/// is kept for the glyph and the rim.
///
/// **No shadow** (owner's call, 2026-08-11). It shipped with the rail glyphs'
/// two-layer dark halo and that halo read as a black smudge on top of the
/// artwork on EVERY wallpaper — a louder failure than the invisibility it was
/// insuring against. The fix is contrast INSIDE the disc, not a bleed outside
/// it. Do not re-add a shadow.
///
/// Static: no controller, no ticker, no repaint boundary. It shares a card with
/// a live `Texture`, and the cheapest mark is one that never asks for a frame.
///
/// It marks live-ness PERMANENTLY, not loading. A live card that has not
/// decoded yet is pixel-identical to a static one (`ViewerMedia` holds a poster
/// under the texture), so this is the only thing telling them apart during the
/// wait — but it stays once the clip plays, because "will this move?" is worth
/// answering on the paused first frame of a neighbour too.
class LiveMark extends StatelessWidget {
  const LiveMark({super.key});

  /// Outer diameter. Under half the Share circle's 52 — the same object, said
  /// quietly. Big enough that the triangle inside it survives at arm's length,
  /// small enough that it never competes with the artwork it annotates.
  static const double diameter = 24;

  /// The play triangle. 14 in a 24 disc leaves a ring of glass around it rather
  /// than a glyph straining at its own edge.
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
        // Centred explicitly: an Icon lays itself out at its own size inside
        // the parent's constraints, so without this it hangs off the top-left
        // of the disc instead of sitting in it.
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
