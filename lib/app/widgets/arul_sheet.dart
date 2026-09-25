import 'package:flutter/material.dart';

import '../../core/haptics/arul_haptics.dart';
import '../../theme/arul_tokens.dart';
import '../theme/theme.dart';
import '../theme/motion.dart';

/// Presents [builder]'s content in an Arul-styled modal bottom sheet.
///
/// Spec: top r24; `#1A0B0F` dark or white light; gold-35% top hairline on dark; 44×4 r2 grabber.
/// Entrance is translateY(24)+fade over 300ms ease, behind a `rgba(20,9,12,.58)` barrier scrim.
/// [gradient] true gives the premium sheet's `#241014 → #1A0B0F` top.
/// [brightness] pins the sheet to one form instead of the app theme -> for a caller whose own
/// surface does not follow that theme (the sign-in wall is always dark over video, so its sheet
/// follows the DEVICE instead). It goes on as a `Theme` ABOVE [ArulSheet], not inside the builder:
/// the scaffold reads `Theme.of` for its surface, grabber and hairline before the child ever builds.
/// Scroll-controlled and sized to its content -> wrap tall content in a scroll view yourself.
Future<T?> showArulSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool gradient = false,
  bool isDismissible = true,
  bool topHairline = true,
  Brightness? brightness,
  Color? surfaceColor,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    isDismissible: isDismissible,
    // On the branch navigator the dock paints OVER the sheet's bottom edge — worst on light,
    // where dock and sheet are both near-white.
    // So present ABOVE the shell -> the barrier scrim and sheet cover the floating dock.
    useRootNavigator: true,
    // ArulSheet paints its own 44×4 grabber -> the theme's drag handle would render a second one.
    showDragHandle: false,
    backgroundColor: Colors.transparent,
    barrierColor: ArulTokens.sheetOverlay,
    // Every Arul sheet follows the app theme — ArulSheet reads `Theme.of(context).brightness` itself.
    builder: (context) {
      final sheet = ArulSheet(
        gradient: gradient,
        topHairline: topHairline,
        surfaceColor: surfaceColor,
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

class ArulSheet extends StatefulWidget {
  const ArulSheet({
    super.key,
    required this.child,
    this.gradient = false,
    this.topHairline = true,
    this.surfaceColor,
  });

  final Widget child;

  final bool gradient;

  /// The 1px gold-35% top hairline, dark only. Off where it reads as a stray line, not an edge.
  final bool topHairline;

  final Color? surfaceColor;

  @override
  State<ArulSheet> createState() => _ArulSheetState();
}

class _ArulSheetState extends State<ArulSheet>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: ArulTokens.sheetEnter,
  );

  /// Armed from [didChangeDependencies] — `reduceMotion` needs an InheritedWidget lookup, and the
  /// sheet must never paint one frame of its +24 offset before that answer exists.
  bool _motionStarted = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_motionStarted) return;
    _motionStarted = true;
    if (context.reduceMotion) {
      // Straight to the SETTLED state: full opacity, zero offset. The sheet appears, it does not rise.
      _c.value = 1;
    } else {
      _c.forward();
    }
  }

  late final Animation<double> _t = CurvedAnimation(
    parent: _c,
    curve: ArulTokens.sheetCurve,
  );

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    const radius = Radius.circular(ArulTokens.sheetTopRadius);

    final surface = DecoratedBox(
      decoration: BoxDecoration(
        color:
            widget.surfaceColor ??
            (isDark ? ArulTokens.darkSheetSurface : ArulTokens.cardBgLight),
        gradient: widget.gradient && isDark
            ? ArulTokens.sheetGradientDark
            : null,
        borderRadius: const BorderRadius.vertical(top: radius),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const _Grabber(),
          Flexible(child: widget.child),
        ],
      ),
    );

    return SafeArea(
      top: false,
      child: AnimatedBuilder(
        animation: _t,
        builder: (context, child) => Opacity(
          opacity: _t.value,
          child: Transform.translate(
            offset: Offset(0, (1 - _t.value) * 24),
            child: child,
          ),
        ),
        child: ClipRRect(
          borderRadius: const BorderRadius.vertical(top: radius),
          child: Stack(
            children: [
              surface,
              // Clipped to the rounded top by the enclosing ClipRRect.
              if (isDark && widget.topHairline)
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: Container(height: 1, color: ArulTokens.goldBorder35),
                ),
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Container(
        width: ArulTokens.grabberWidth,
        height: ArulTokens.grabberHeight,
        decoration: BoxDecoration(
          color: isDark
              ? ArulTokens.grabberColorDark
              : ArulTokens.grabberColorLight,
          borderRadius: BorderRadius.circular(ArulTokens.grabberRadius),
        ),
      ),
    );
  }
}

/// One option in an Arul sheet — icon chip, title, one short sub, on its own bordered card.
///
/// Every sheet that offers a LIST of choices reads this, so the theme picker and the help sheet
/// cannot drift apart; the language picker is the same card language laid out as a 2-column grid.
/// Flat rows separated by nothing read as one undifferentiated block — the gap and the rim are what
/// make three options look like three things.
///
/// [selected] is the picker state — gold rim, gold tint, gold type and a check, as on a language
/// tile. [destructive] is the one irreversible act. A row is never both.
class ArulSheetRow extends StatelessWidget {
  const ArulSheetRow({
    super.key,
    this.icon,
    this.glyph,
    required this.title,
    required this.sub,
    required this.onTap,
    this.haptic = ArulHapticStyle.tap,
    this.identifier,
    this.selected = false,
    this.destructive = false,
  }) : assert(icon != null || glyph != null, 'a row needs one or the other'),
       assert(
         !(selected && destructive),
         'a row is a choice or an act, never both',
       );

  final IconData? icon;

  /// A custom mark, for where a Material icon would be the wrong voice (the brand gopuram).
  /// Takes the row's resolved ink so it tints with the state.
  final Widget Function(Color color)? glyph;

  final String title;
  final String sub;
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final surface = isDark ? ArulTokens.cardBgDark04 : ArulTokens.cardBgLight;
    // Gold TYPE dies on ivory -> goldInkLight is the ink role for exactly this (arul_tokens.dart).
    final goldInk = isDark ? ArulTokens.gold : ArulTokens.goldInkLight;

    final Color fill = selected ? ArulTokens.goldTintFill10 : surface;
    // On LIGHT the neutral row is already maroon-tinted, so maroonBorder18 / maroonTintFill08 land
    // a percent or two off it and the delete row read identical to its neighbour on device. The rim
    // and chip take the logout pill's values instead — the app's existing destructive voice.
    final Color border = selected
        ? ArulTokens.gold
        : destructive
        ? (isDark ? _maroonRimDark : _maroonRimLight)
        : (isDark ? ArulTokens.cardBorderDark14 : ArulTokens.cardBorderLight);
    // Inverted on a selected row: a quiet well inside the gold card, so the chip does not silt up.
    final Color chipBg = selected
        ? surface
        : destructive
        ? (isDark ? _maroonChipDark : _maroonChipLight)
        : (isDark ? ArulTokens.goldTintFill10 : ArulTokens.maroonTintFill07);
    // Maroon ink dies on the dark ground -> the logout pill's warm pale, the app's one destructive
    // voice on dark (`_LogoutButton` derives the same lerp; no token exposes it).
    final Color accent = selected
        ? goldInk
        : destructive
        ? (isDark ? _destructiveInkDark : ArulTokens.maroon)
        : (isDark ? ArulTokens.gold : ArulTokens.maroon);
    final Color titleColor = (selected || destructive)
        ? accent
        : (isDark ? ArulTokens.darkText : ArulTokens.lightText);
    final Color subColor = isDark
        ? ArulTokens.darkTextSecondary
        : ArulTokens.lightSecondary;

    final row = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => ArulHaptics.fire(haptic),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: fill,
          border: Border.all(color: border, width: selected ? 1.5 : 1),
          borderRadius: BorderRadius.circular(ArulTokens.rowRadius),
        ),
        child: Row(
          children: [
            Container(
              width: ArulTokens.iconChipSize,
              height: ArulTokens.iconChipSize,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: chipBg,
                borderRadius: BorderRadius.circular(ArulTokens.iconChipRadius),
              ),
              child:
                  glyph?.call(accent) ??
                  Icon(icon, size: ArulTokens.iconChipIconSize, color: accent),
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
                  const SizedBox(height: 1),
                  Text(sub, style: ArulTokens.rowSub.copyWith(color: subColor)),
                ],
              ),
            ),
            if (selected) ...[
              const SizedBox(width: 8),
              Icon(Icons.check_circle, size: 20, color: goldInk),
            ],
          ],
        ),
      ),
    );

    return Semantics(
      container: true,
      button: true,
      selected: selected,
      identifier: identifier,
      child: row,
    );
  }
}

/// Air between the option cards. Wider than a divider on purpose — separate things, not a list.
const double kSheetRowGap = 10;

// Derived from ArulTokens.maroon where no token exposes the alpha — the logout pill's own values,
// so the destructive-leaning surfaces read as one.
final Color _maroonRimDark = ArulTokens.maroon.withValues(alpha: 0.55);
final Color _maroonChipDark = ArulTokens.maroon.withValues(alpha: 0.35);
final Color _maroonRimLight = ArulTokens.maroon.withValues(alpha: 0.35);
final Color _maroonChipLight = ArulTokens.maroon.withValues(alpha: 0.14);
final Color _destructiveInkDark = Color.lerp(
  ArulTokens.ivory,
  ArulTokens.maroon,
  0.14,
)!;
