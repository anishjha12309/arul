import 'package:flutter/material.dart';

import '../../../app/l10n/app_localizations.dart';
import '../../../theme/arul_tokens.dart';

/// The gold "Current" pill on the ringtone row the phone is actually ringing with.
///
/// Presence IS the signal — it carries no icon and no state of its own, and the row either renders
/// it or does not. Never interactive: a second tap target inside the row would compete with Set.
///
/// SIZED TO THE SUBTITLE LINE on purpose. `RingtoneRow`'s height is PINNED and a two-line title over
/// a deity label already fills that box exactly, so this has to fit inside a line the row already
/// reserves — it can never be a line of its own. 10.5px of type rounds to an 11dp box, plus 2×[_padV]
/// = 16dp, against the 16.8dp the caption line reserves; at the 0.85 text scale that is 14 against
/// 14.28, and the margin only widens from there. Which is also why there is no border: a hairline
/// would cost 2dp the smallest scale does not have.
class CurrentRingtoneBadge extends StatelessWidget {
  const CurrentRingtoneBadge({super.key});

  /// One step under [ArulTokens.caption] — a marker, not a second label competing with the title.
  static const double _fontSize = 10.5;

  /// The pill's inset. The VERTICAL half is what spends the row's height budget — see the class doc.
  static const double _padH = 7;
  static const double _padV = 2.5;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: ArulTokens.goldTintFill14,
        borderRadius: BorderRadius.circular(ArulTokens.pillRadius),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: _padH, vertical: _padV),
        child: Text(
          AppLocalizations.of(context).ringtoneCurrentBadge,
          maxLines: 1,
          // `chipActive` carries the pinned line box every small label here needs: without its
          // `height: 1` and even leading the ambient 1.45 would make this pill ~5dp taller than the
          // line it has to fit inside.
          style: ArulTokens.chipActive.copyWith(
            fontSize: _fontSize,
            // Gold is the accent, but gold TYPE does not carry on the light card -> ink, not fill.
            color: isDark ? ArulTokens.gold : ArulTokens.goldInkLight,
          ),
        ),
      ),
    );
  }
}
