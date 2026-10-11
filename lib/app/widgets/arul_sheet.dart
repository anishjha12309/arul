import 'package:flutter/material.dart';

import '../../core/haptics/arul_haptics.dart';
import '../../theme/arul_palette.dart';
import '../../theme/arul_tokens.dart';
import '../theme/motion.dart';
import '../theme/theme.dart';
import 'arul_pressable.dart';
import 'arul_surface.dart';

/// Presents [builder]'s content in an Arul-styled modal bottom sheet.
/// [brightness] pins the sheet to one form instead of the app theme -> for a caller whose own
/// surface does not follow that theme (the sign-in wall is always dark over video, so its sheet
/// follows the DEVICE instead). It goes on as a `Theme` ABOVE [ArulSheet], not inside the builder:
/// the scaffold reads `Theme.of` for its surface, grabber and hairline before the child ever builds.
/// Scroll-controlled and sized to its content -> wrap tall content in a scroll view yourself.
Future<T?> showArulSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool isDismissible = true,
  bool enableDrag = true,
  bool topHairline = true,
  Brightness? brightness,
  Color? surfaceColor,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    isDismissible: isDismissible,
    enableDrag: enableDrag,
    // On the branch navigator the dock paints OVER the sheet's bottom edge — worst on light,
    // where dock and sheet are both near-white.
    // So present ABOVE the shell -> the barrier scrim and sheet cover the floating dock.
    useRootNavigator: true,
    // ArulSheet paints its own 44×4 grabber -> the theme's drag handle would render a second one.
    showDragHandle: false,
    backgroundColor: Colors.transparent,
    barrierColor: ArulTokens.sheetOverlay,
    sheetAnimationStyle: context.reduceMotion
        ? AnimationStyle.noAnimation
        : Motion.sheet,
    builder: (context) {
      final sheet = ArulSheet(
        topHairline: topHairline,
        surfaceColor: surfaceColor,
        // A handle promises the drag; a sheet that cannot be dragged away draws none.
        grabber: enableDrag,
        child: Builder(builder: builder),
      );
      if (brightness == null) return sheet;
      return Theme(
        data: brightness == Brightness.dark
            ? ArulTheme.dark()
            : ArulTheme.light(),
        child: sheet,
      );
    },
  );
}

class ArulSheet extends StatelessWidget {
  const ArulSheet({
    super.key,
    required this.child,
    this.topHairline = true,
    this.surfaceColor,
    this.grabber = true,
  });

  final Widget child;

  final bool grabber;

  /// The gold lit edge along the rounded top, on dark.
  final bool topHairline;

  final Color? surfaceColor;

  @override
  Widget build(BuildContext context) {
    const radius = BorderRadius.vertical(
      top: Radius.circular(ArulTokens.sheetTopRadius),
    );
    return ClipRRect(
      borderRadius: radius,
      child: ArulSurface(
        borderRadius: radius,
        color: surfaceColor,
        // A sheet meets the screen's edges and sits on its own scrim: no rim, no lift.
        rim: false,
        shadow: const [],
        litEdge: topHairline,
        // The ground runs under the gesture bar and only the content keeps clear of it: a sheet
        // stopped above the bar left a strip of scrim beneath it.
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (grabber) const _Grabber(),
              Flexible(child: child),
            ],
          ),
        ),
      ),
    );
  }
}

class _Grabber extends StatelessWidget {
  const _Grabber();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Container(
        width: ArulTokens.grabberWidth,
        height: ArulTokens.grabberHeight,
        decoration: BoxDecoration(
          color: ArulPalette.of(context).grabber,
          borderRadius: BorderRadius.circular(ArulTokens.grabberRadius),
        ),
      ),
    );
  }
}

/// One option in an Arul sheet — icon chip, title, an optional short sub, on its own bordered card.
/// [selected] is the picker state — gold rim, gold tint, gold type and a check, as on a language
/// tile. [destructive] is the one irreversible act. A row is never both.
class ArulSheetRow extends StatelessWidget {
  const ArulSheetRow({
    super.key,
    this.icon,
    this.glyph,
    this.leading,
    required this.title,
    this.sub,
    required this.onTap,
    this.haptic = ArulHapticStyle.tap,
    this.identifier,
    this.selected = false,
    this.destructive = false,
  }) : assert(
         icon != null || glyph != null || leading != null,
         'a row needs a mark',
       ),
       assert(
         !(selected && destructive),
         'a row is a choice or an act, never both',
       );

  final IconData? icon;

  /// A custom mark, for where a Material icon would be the wrong voice (a deity's line art).
  /// Takes the row's resolved ink so it tints with the state.
  final Widget Function(Color color)? glyph;

  /// Replaces the icon chip outright — the premium medallion on the row that leads to /premium.
  final Widget? leading;

  final String title;
  final String? sub;
  final VoidCallback onTap;

  /// The beat this row answers with. A picker ticks; an action presses; deleting lands hard.
  final ArulHapticStyle haptic;

  final String? identifier;

  final bool selected;

  /// Deleting is irreversible -> the rim, the chip and the title carry maroon. The GROUND does not:
  /// a filled red row beside quiet ones reads as the thing to press.
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final p = ArulPalette.of(context);

    final fill = selected ? ArulTokens.goldTintFill10 : p.card;
    // On LIGHT the neutral row is already maroon-tinted, so maroonBorder18 / maroonTintFill08 land
    // a percent or two off it and the delete row read identical to its neighbour on device. The rim
    // and chip take the logout pill's values instead — the app's existing destructive voice.
    final border = selected
        ? ArulTokens.gold
        : destructive
        ? p.destructiveRim
        : p.border;
    // Inverted on a selected row: a quiet well inside the gold card, so the chip does not silt up.
    final chipBg = selected
        ? p.card
        : destructive
        ? p.destructiveChip
        : p.accentTint;
    final accent = selected
        ? p.goldInk
        : destructive
        ? p.destructiveInk
        : p.accent;
    final titleColor = (selected || destructive) ? accent : p.text;

    return ArulPressable(
      haptic: haptic,
      identifier: identifier,
      selected: selected,
      onTap: onTap,
      builder: (context, pressed) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          // Held: the accent's own wash over the ground, the same family as the selected tint.
          color: pressed ? Color.alphaBlend(p.accentTint, fill) : fill,
          border: Border.all(color: border, width: selected ? 1.5 : 1),
          borderRadius: BorderRadius.circular(ArulTokens.rowRadius),
        ),
        child: Row(
          children: [
            leading ??
                Container(
                  width: ArulTokens.iconChipSize,
                  height: ArulTokens.iconChipSize,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: chipBg,
                    borderRadius: BorderRadius.circular(
                      ArulTokens.iconChipRadius,
                    ),
                  ),
                  child:
                      glyph?.call(accent) ??
                      Icon(
                        icon,
                        size: ArulTokens.iconChipIconSize,
                        color: accent,
                      ),
                ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: ArulTokens.rowTitle.copyWith(color: titleColor),
                  ),
                  if (sub case final sub?) ...[
                    const SizedBox(height: 1),
                    Text(
                      sub,
                      style: ArulTokens.rowSub.copyWith(color: p.textSecondary),
                    ),
                  ],
                ],
              ),
            ),
            if (selected) ...[
              const SizedBox(width: 8),
              Icon(Icons.check_circle, size: 20, color: p.goldInk),
            ],
          ],
        ),
      ),
    );
  }
}

/// Air between the option cards. Wider than a divider on purpose — separate things, not a list.
const double kSheetRowGap = 10;
