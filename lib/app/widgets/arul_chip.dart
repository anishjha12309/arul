import 'package:flutter/material.dart';

import '../../core/haptics/arul_haptics.dart';
import '../../theme/arul_tokens.dart';
import '../theme/motion.dart';

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
class ArulChip extends StatefulWidget {
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

  /// The browse chip's fixed DRAWN height. Its tap target is [ArulTokens.minHitTarget].
  /// The category chip's VISUAL height. Public because the loading skeletons draw the same pill and
  /// must not read [categoryStripHeight], which is the hit box -> a skeleton built from the hit box
  /// shrank to 34 the moment the catalog landed.
  static const double categoryHeight = 34;

  /// The height a strip must give a row of [ArulChipVariant.category] chips so the hit area that
  /// surrounds their 34dp visual is not clipped back off.
  static const double categoryStripHeight = ArulTokens.minHitTarget;

  @override
  State<ArulChip> createState() => _ArulChipState();
}

class _ArulChipState extends State<ArulChip> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final label = widget.label;
    final selected = widget.selected;
    final onTap = widget.onTap;
    final variant = widget.variant;
    final identifier = widget.identifier;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final (Color bg, Color border, Color fg) = _palette(
      variant,
      selected,
      isDark,
    );

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
      // A chip picks between values -> the lightest tick, never a button press, and on press-DOWN;
      // the pill dips under the finger until the selection lands on release.
      onTapDown: onTap == null
          ? null
          : (_) {
              ArulHaptics.selection();
              setState(() => _pressed = true);
            },
      onTapUp: onTap == null ? null : (_) => setState(() => _pressed = false),
      onTapCancel: onTap == null
          ? null
          : () => setState(() => _pressed = false),
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      // Every chip DRAWS its own height and is TAPPED at [ArulTokens.minHitTarget] — the visual is
      // the handoff's and does not move, the slack above and below is transparent hit area.
      // `opaque` is what makes that slack tappable rather than decorative. The strips that host the
      // browse row own the matching height; a form's Wrap simply runs a little airier.
      child: SizedBox(
        height: ArulTokens.minHitTarget,
        child: Center(
          widthFactor: 1,
          child: AnimatedOpacity(
            // Holds at 1 when motion is reduced; the tick still answers the press.
            opacity: _pressed && !context.reduceMotion ? 0.6 : 1,
            duration: context.reduceMotion ? Duration.zero : Motion.pressDip,
            child: visual,
          ),
        ),
      ),
    );

    return Semantics(
      container: true,
      button: onTap != null,
      selected: selected,
      label: label,
      identifier: identifier,
      // The label is announced once, as this control's name.
      excludeSemantics: true,
      child: chip,
    );
  }

  static const double _categoryHeight = ArulChip.categoryHeight;

  static (Color, Color, Color) _palette(
    ArulChipVariant variant,
    bool selected,
    bool isDark,
  ) {
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
