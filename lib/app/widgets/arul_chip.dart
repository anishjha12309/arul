import 'package:flutter/material.dart';

import '../../core/haptics/arul_haptics.dart';
import '../../theme/arul_tokens.dart';

/// Which surface an [ArulChip] sits on.
enum ArulChipVariant {
  /// Over the feed's media — a fixed dark palette, so it stays legible on any wallpaper.
  feed,

  /// On a themed surface — the Upload screen's category chips. Follows light/dark.
  surface,

  /// The browse-axis chip row on a themed surface — the Ringtones screen. Follows light/dark.
  /// A browse filter should recede until chosen, where a form chip must read as an available answer.
  /// So this is taller and flatter than [surface], with a SECONDARY inactive label, not the primary.
  category,
}

/// The category / selection chip used by the feed row and the Upload screen.
///
/// Feed spec: pad 7×15, r999; inactive ivory-92% on `rgba(20,9,12,.42)`; active SOLID gold on dark.
/// Surface spec: unselected light is white on a maroon-12% border; selected is a solid brand fill.
class ArulChip extends StatelessWidget {
  const ArulChip({
    super.key,
    required this.label,
    required this.selected,
    this.onTap,
    this.variant = ArulChipVariant.feed,
    this.identifier,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final ArulChipVariant variant;

  /// Stable accessibility id (`Semantics(identifier:)`): announced to nobody, so it is free at
  /// the UI layer and survives every locale.
  /// Never announced and never visible — see that folder's README for the list.
  final String? identifier;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final (Color bg, Color border, Color fg) = _palette(isDark);

    final Widget visual = Container(
      // The browse row is a fixed 34 tall with 16 side padding; the other two size off the label.
      height: variant == ArulChipVariant.category ? _categoryHeight : null,
      alignment: variant == ArulChipVariant.category ? Alignment.center : null,
      padding: variant == ArulChipVariant.category
          ? const EdgeInsets.symmetric(horizontal: 16)
          // ArulTokens.chip pins `height: 1` -> the label's box lost the theme's 1.45 leading, ~6px.
          // So vertical padding is 10, not the spec's 7 -> the chip stays the size it always was.
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
    );

    final chip = GestureDetector(
      // A chip picks between values -> the lightest tick, never a button press, and on press-DOWN.
      onTapDown: onTap == null ? null : (_) => ArulHaptics.selection(),
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      // The browse chip DRAWS 34 and is TAPPED at 44 — the visual is the handoff's and does not
      // move, the extra 5 above and below is transparent hit area. `opaque` is what makes the
      // padding tappable rather than decorative. The strips that host it own the matching height.
      child: variant == ArulChipVariant.category
          ? SizedBox(
              height: ArulTokens.minHitTarget,
              child: Center(widthFactor: 1, child: visual),
            )
          : visual,
    );

    if (identifier == null) return chip;
    return Semantics(container: true, identifier: identifier, child: chip);
  }

  /// The browse chip's fixed DRAWN height. Its tap target is [ArulTokens.minHitTarget].
  static const double _categoryHeight = 34;

  /// The height a strip must give a row of [ArulChipVariant.category] chips so the hit area that
  /// surrounds their 34dp visual is not clipped back off.
  static const double categoryStripHeight = ArulTokens.minHitTarget;

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
          // Solid gold on dark, solid maroon on light — borderless, so the pill reads as one token.
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
