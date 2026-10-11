import 'package:flutter/material.dart';

/// The detailed gopuram: the premium screens' temple ornament, redrawn at 4× so it stays sharp at
/// loading-state size. Loading and empty states draw this. Marks under ~24 dp keep [GopuramMark],
/// whose solid silhouette survives a size this line art does not.
class GopuramArt extends StatelessWidget {
  const GopuramArt({super.key, required this.height, this.color});

  static const asset = 'assets/images/gopuram_temple.webp';

  /// Its height on every loading and empty state, so swapping one state for another never resizes it.
  static const double stateHeight = 72;

  /// Width over height of the drawing (268 × 384 px).
  static const double aspect = 268 / 384;

  final double height;

  /// Tints the line art. Null keeps the ornament's own antique gold, as the premium screens show it.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: Image.asset(
        asset,
        width: height * aspect,
        height: height,
        fit: BoxFit.contain,
        // Mipmapped minification: the 384 px source drawn at ~170 px keeps its hairlines.
        filterQuality: FilterQuality.medium,
        color: color,
        colorBlendMode: color == null ? null : BlendMode.srcIn,
        // A rebuilt state (a reel swapping cards) never blinks the art out while it re-resolves.
        gaplessPlayback: true,
      ),
    );
  }
}
