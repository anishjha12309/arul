import 'package:flutter/material.dart';

import '../../core/haptics/arul_haptics.dart';
import '../../theme/arul_tokens.dart';

/// Which surface an [ArulChip] sits on.
enum ArulChipVariant {
  /// Over the feed's media (Spec > Reel feed chips). Fixed dark palette so it
  /// stays legible on any wallpaper.
  feed,

  /// On a themed surface — the Upload screen's category chips (Spec > Upload).
  /// Follows light/dark.
  surface,

  /// The browse-axis chip row on a themed surface — the Ringtones screen
  /// (design_handoff_ringtones_screen). Taller and flatter than [surface], and
  /// its inactive label is the secondary text colour rather than the primary:
  /// a browse filter should recede until it is chosen, where a form chip like
  /// Upload's must read as an available answer. Follows light/dark.
  category,
}

/// The category / selection chip used by the feed row and the Upload screen.
///
/// Feed (spec): pad 7×15, r999; inactive bg `rgba(20,9,12,.42)` border
/// `rgba(250,245,236,.22)` ivory-92% 13.5/500; active SOLID gold, `#14090C`
/// text /600.
///
/// Surface (Spec > Upload): unselected light = white bg, maroon-12% border;
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
      // A chip picks between values, so it gets the lightest tick rather than a
      // button press — and on press-down, like every other control.
      onTapDown: onTap == null ? null : (_) => ArulHaptics.selection(),
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        // The browse row is spec'd as a fixed 34 tall with 16 of side padding;
        // the other two size themselves off the label's own line box.
        height: variant == ArulChipVariant.category ? _categoryHeight : null,
        alignment: variant == ArulChipVariant.category
            ? Alignment.center
            : null,
        padding: variant == ArulChipVariant.category
            ? const EdgeInsets.symmetric(horizontal: 16)
            // 10, not the spec's 7: the label's line box lost the theme's 1.45
            // leading when the chip styles pinned `height: 1` (see
            // ArulTokens.chip), so the padding takes back the ~6px the box
            // used to carry and this chip stays the size it has always been.
            : const EdgeInsets.symmetric(horizontal: 15, vertical: 10),
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

  /// The browse chip's fixed height.
  static const double _categoryHeight = 34;

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
      case ArulChipVariant.category:
        if (selected) {
          // Solid gold on dark, solid maroon on light — borderless, so the
          // rim is the fill and the pill reads as one flat token.
          final fill = isDark ? ArulTokens.gold : ArulTokens.maroon;
          final fg = isDark ? ArulTokens.darkSurface : ArulTokens.ivory;
          return (fill, fill, fg);
        }
        if (isDark) {
          return (
            ArulTokens.cardBgDark045,
            ArulTokens.cardBorderDark12,
            ArulTokens.darkTextSecondary,
          );
        }
        return (
          ArulTokens.cardBgLight,
          ArulTokens.cardBorderLight,
          ArulTokens.lightBody,
        );
    }
  }
}
