import 'package:flutter/material.dart';

import '../../theme/arul_tokens.dart';

/// Presents [builder]'s content in an Arul-styled modal bottom sheet.
///
/// README (Apply / Theme / Language / Premium / Edit-name sheets): rounded top
/// r24; dark surface `#1A0B0F` (optionally a `#241014 → #1A0B0F` gradient top for
/// the premium sheet) or white on light; a 1px gold-35% top hairline on dark; a
/// 44×4 r2 grabber; entrance translateY(24)+fade 300ms ease; barrier scrim
/// `rgba(20,9,12,.58)`.
///
/// Pass [gradient] true for the gradient-top variant (premium sheet). The sheet
/// is scroll-controlled and sizes to its content; wrap tall content in a scroll
/// view yourself.
Future<T?> showArulSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool gradient = false,
  bool isDismissible = true,
  bool topHairline = true,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    isDismissible: isDismissible,
    // Present ABOVE the shell so the barrier scrim + sheet cover the floating
    // nav dock (Scaffold.bottomNavigationBar, extendBody). Without this the
    // sheet opens on the branch navigator inside the body and the dock paints
    // on top of the sheet's bottom edge — a visible collision, worst on the
    // light theme where dock and sheet are both near-white.
    useRootNavigator: true,
    // ArulSheet paints its own 44×4 grabber — the theme's Material drag
    // handle would render a second one above the sheet.
    showDragHandle: false,
    backgroundColor: Colors.transparent,
    barrierColor: ArulTokens.sheetOverlay, // rgba(20,9,12,.58)
    // Every Arul sheet follows the app theme (dark surface on dark, white on
    // light) — ArulSheet reads Theme.of(context).brightness itself.
    builder: (context) => ArulSheet(
      gradient: gradient,
      topHairline: topHairline,
      child: builder(context),
    ),
  );
}

/// The visual scaffold of an Arul bottom sheet: surface + top hairline + grabber
/// + the translateY(24)+fade entrance. Used by [showArulSheet]; also usable
/// directly (e.g. inside a custom route).
class ArulSheet extends StatefulWidget {
  const ArulSheet({
    super.key,
    required this.child,
    this.gradient = false,
    this.topHairline = true,
  });

  final Widget child;

  /// Gradient-top variant (`#241014 → #1A0B0F`) for the premium sheet.
  final bool gradient;

  /// The 1px gold-35% top hairline (dark only). Off for sheets where it reads
  /// as a stray line rather than an edge — e.g. the theme picker.
  final bool topHairline;

  @override
  State<ArulSheet> createState() => _ArulSheetState();
}

class _ArulSheetState extends State<ArulSheet>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: ArulTokens.sheetEnter, // 300ms
  )..forward();

  late final Animation<double> _t = CurvedAnimation(
    parent: _c,
    curve: ArulTokens.sheetCurve, // ease
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
        color: isDark ? ArulTokens.darkSheetSurface : ArulTokens.cardBgLight,
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
              // 1px gold-35% top hairline (dark only). Clipped to the rounded
              // top by the enclosing ClipRRect.
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

/// The drag grabber — 44×4 r2, `rgba(250,245,236,.25)` dark / `rgba(43,17,22,.2)`
/// light (README > Spacing / radii / misc).
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
