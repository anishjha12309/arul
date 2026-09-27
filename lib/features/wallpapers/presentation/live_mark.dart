import 'package:flutter/material.dart';

import '../../../theme/arul_tokens.dart';

/// The live-wallpaper marker: a play triangle held in a small glass disc.
class LiveMark extends StatelessWidget {
  const LiveMark({super.key});

  /// Outer diameter — under half the Share circle's 52: the same object, said quietly. Big enough
  /// that the triangle survives at arm's length, small enough never to compete with the artwork.
  static const double diameter = 24;

  /// The play triangle — 14 in a 24 disc leaves a ring of glass, not a glyph straining at the edge.
  static const double glyphSize = 14;

  @override
  Widget build(BuildContext context) {
    // `arul_live_mark` is the one machine-readable tell of a live card — the mark is already the
    // ONLY signal on screen. Never announced.
    return Semantics(
      container: true,
      identifier: 'arul_live_mark',
      child: const SizedBox.square(
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
      ),
    );
  }
}
