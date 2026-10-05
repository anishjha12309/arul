import 'package:flutter/material.dart';

import '../../theme/arul_tokens.dart';
import 'arul_icon_tap.dart';

/// The one header band every top-level tab wears.
class ArulScreenHeader extends StatelessWidget {
  const ArulScreenHeader({
    super.key,
    required this.title,
    this.titleStyle,
    this.titleDrop = 0,
    this.leading,
    this.actions = const [],
  });

  final String title;

  /// Overrides [ArulTokens.screenHeaderTitle] — ONE caller: the feed, whose "Arul" is the WORDMARK.
  /// A title changing size between cross-fading tabs reads as the whole screen jumping.
  /// So never use this to make a tab special — a wordmark is a different object; a title is not.
  final TextStyle? titleStyle;

  /// Optical drop for the title, logical px, positive = down.
  /// A TRANSLATE -> it moves paint, never the band, so the reel below cannot be pushed around by it.
  final double titleDrop;

  final Widget? leading;

  /// Trailing controls, right-aligned with [_actionGap] between them.
  /// Each MUST be [bandHeight] tall and DRAW [ArulTokens.headerControlSize] inside [bandPadding]
  /// (see [ArulIconTap.glyph]) -> the band is the same height on every tab, and the control is
  /// tapped at Android's 48 while the eye still sees 34.
  final List<Widget> actions;

  /// The band's full height: the control row plus the air either side. 48 — which is also
  /// [ArulTokens.minHitTarget], so an action that spans the band is a real target for free.
  static const double bandHeight =
      ArulTokens.headerTopPadding +
      ArulTokens.headerControlSize +
      ArulTokens.headerBottomPadding;

  static const EdgeInsets bandPadding = EdgeInsets.only(
    top: ArulTokens.headerTopPadding,
    bottom: ArulTokens.headerBottomPadding,
  );

  static const double _leadingGap = 12;

  static const double _actionGap = 8;

  /// **Optical left inset for the title — tune it if the title reads too near the screen edge.**
  /// A [leading] glyph keeps the true gutter — unlike type it has a real edge.
  static const double _titleOpticalInset = 3;

  /// A localized title renders in its Noto fallback, whose taller ascent rides the ink 4–9 dp above
  /// the Marcellus titles' (measured on device against the wordmark's). Drop it back per script.
  static const _scriptDrop = <String, double>{
    'hi': 7.2,
    'kn': 8.8,
    'ml': 6.1,
    'ta': 3.6,
    'te': 7.0,
  };

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Padding(
      // The trailing action's spare target width is laid out INTO the gutter, never translated
      // there -> a transform paints outside its own hit bounds and the outer strip ignores taps.
      padding: EdgeInsets.only(
        left: ArulTokens.screenPadding,
        right: actions.isEmpty
            ? ArulTokens.screenPadding
            : ArulTokens.screenPadding - ArulIconTap.headerSpill,
      ),
      child: SizedBox(
        height: bandHeight,
        child: Row(
          children: [
            if (leading != null) ...[
              Padding(padding: bandPadding, child: leading),
              const SizedBox(width: _leadingGap),
            ],
            // A localized title runs half again as long and the OS font size is not clamped here.
            // So the title is what must give way -> Expanded, never a Spacer.
            Expanded(
              // Horizontal is PADDING -> it reserves its 3px, so a long title measures against
              // the real space it has.
              // Vertical is a TRANSLATE -> it must add no height, or the band grows and the reel with it.
              child: Padding(
                padding: bandPadding.add(
                  const EdgeInsets.only(left: _titleOpticalInset),
                ),
                child: Transform.translate(
                  offset: Offset(
                    0,
                    titleDrop +
                        (titleStyle == null
                            ? _scriptDrop[Localizations.localeOf(
                                    context,
                                  ).languageCode] ??
                                  0
                            : 0),
                  ),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        title,
                        maxLines: 1,
                        style: (titleStyle ?? ArulTokens.screenHeaderTitle).copyWith(
                          // Gold on dark, not ivory -> the header reads as brand, not as a page
                          // label. Light keeps its ink — gold on ivory has nothing to carry it.
                          color: isDark
                              ? ArulTokens.gold
                              : ArulTokens.lightText,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            // Hands the title back the width the spill took from the gutter -> it measures as before.
            if (actions.isNotEmpty)
              const SizedBox(width: ArulIconTap.headerSpill),
            for (final action in actions) ...[
              const SizedBox(width: _actionGap),
              action,
            ],
          ],
        ),
      ),
    );
  }
}
