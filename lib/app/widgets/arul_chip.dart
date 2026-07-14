import 'package:flutter/material.dart';

import '../../theme/arul_tokens.dart';

/// Which surface an [ArulChip] sits on.
enum ArulChipVariant {
  /// Over the feed's media (README > Reel feed chips). Fixed dark palette so it
  /// stays legible on any wallpaper.
  feed,

  /// On a themed surface — the Upload screen's category chips (README > Upload).
  /// Follows light/dark.
  surface,
}

/// The category / selection chip used by the feed row and the Upload screen.
///
/// Feed (README): pad 7×15, r999; inactive bg `rgba(20,9,12,.42)` border
/// `rgba(250,245,236,.22)` ivory-92% 13.5/500; active SOLID gold, `#14090C`
/// text /600.
///
/// Surface (README > Upload): unselected light = white bg, maroon-12% border;
/// selected = solid gold on dark / solid maroon on light, with contrasting label.
class ArulChip extends StatelessWidget {
  const ArulChip({
    super.key,
    required this.label,
    required this.selected,
    this.onTap,
    this.variant = ArulChipVariant.feed,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final ArulChipVariant variant;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final (Color bg, Color border, Color fg) = _palette(isDark);

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 7),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(ArulTokens.pillRadius),
          border: Border.all(color: border),
        ),
        child: Text(
          label,
          style: (selected ? ArulTokens.chipActive : ArulTokens.chip).copyWith(
            color: fg,
          ),
        ),
      ),
    );
  }

  (Color, Color, Color) _palette(bool isDark) {
    switch (variant) {
      case ArulChipVariant.feed:
        if (selected) {
          // Solid gold, dark text.
          return (ArulTokens.gold, ArulTokens.gold, ArulTokens.darkSurface);
        }
        return (
          const Color.fromRGBO(20, 9, 12, 0.42), // rgba(20,9,12,.42)
          const Color.fromRGBO(250, 245, 236, 0.22), // rgba(250,245,236,.22)
          const Color.fromRGBO(250, 245, 236, 0.92), // ivory 92%
        );
      case ArulChipVariant.surface:
        if (selected) {
          // Solid gold on dark, solid maroon on light.
          final fill = isDark ? ArulTokens.gold : ArulTokens.maroon;
          final fg = isDark ? ArulTokens.darkSurface : ArulTokens.ivory;
          return (fill, fill, fg);
        }
        if (isDark) {
          return (
            ArulTokens.cardBgDark05,
            ArulTokens.cardBorderDark14,
            ArulTokens.darkText,
          );
        }
        return (
          ArulTokens.cardBgLight,
          ArulTokens.cardBorderLight,
          ArulTokens.lightText,
        );
    }
  }
}
