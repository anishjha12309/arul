import 'package:flutter/material.dart';

import '../../theme/arul_palette.dart';
import '../../theme/arul_tokens.dart';
import 'gopuram_art.dart';

/// The temple crest over a dialog's title: gold rules fading in to a floret either side of the
/// gopuram — the premium dialogs' ornament, at app scale, in the ornaments' own antique gold.
class ArulCrest extends StatelessWidget {
  const ArulCrest({super.key});

  @override
  Widget build(BuildContext context) => const ExcludeSemantics(
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _Wing(mirrored: false),
        SizedBox(width: ArulTokens.crestGap),
        GopuramArt(height: ArulTokens.crestArtHeight),
        SizedBox(width: ArulTokens.crestGap),
        _Wing(mirrored: true),
      ],
    ),
  );
}

class _Wing extends StatelessWidget {
  const _Wing({required this.mirrored});

  final bool mirrored;

  static const _floret = 'assets/premium/ornament_floret.webp';

  @override
  Widget build(BuildContext context) {
    const g = ArulTokens.paywallBrandRule;
    final rule = SizedBox(
      width: ArulTokens.crestRuleWidth,
      height: ArulTokens.paywallOrnamentRuleThickness,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: mirrored
              ? LinearGradient(begin: g.end, end: g.begin, colors: g.colors)
              : g,
        ),
      ),
    );
    final floret = Image.asset(
      _floret,
      width: ArulTokens.crestFloretSize,
      filterQuality: FilterQuality.medium,
    );
    const gap = SizedBox(width: ArulTokens.crestGap - 2);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: mirrored ? [floret, gap, rule] : [rule, gap, floret],
    );
  }
}

/// A round premium badge: a gold ring around premium line art, as the paywall's feature medallions
/// wear it. It marks the one row that leads into the subscription.
class ArulMedallion extends StatelessWidget {
  const ArulMedallion({
    super.key,
    required this.child,
    this.size = ArulTokens.medallionSize,
  });

  final Widget child;
  final double size;

  @override
  Widget build(BuildContext context) {
    final p = ArulPalette.of(context);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: p.medallionFill,
        border: Border.all(
          color: p.medallionRing,
          width: ArulTokens.medallionRing,
        ),
      ),
      child: child,
    );
  }
}
