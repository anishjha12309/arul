import 'package:flutter/material.dart';

import '../../theme/arul_tokens.dart';

/// The one header band every top-level tab wears.
///
/// The tabs cross-fade -> the title is the anchor while the content swaps underneath.
/// Three sizes and three drops made every tab switch read as the whole screen jumping.
/// One band, one type scale, one control height -> a tab's difference goes in [actions], not geometry.
/// The reel's card geometry is solved from the height left below this band (`feed_screen.dart`).
/// So moving the header resizes the reel -> the metrics are the feed's, unchanged.
class ArulScreenHeader extends StatelessWidget {
  const ArulScreenHeader({
    super.key,
    required this.title,
    this.titleStyle,
    this.titleDrop = 0,
    this.leading,
    this.actions = const [],
  });

  /// The screen's name, in [ArulTokens.screenHeaderTitle] — Marcellus, so Latin-safe brand type.
  /// A localized title still renders, through the Noto fallbacks.
  final String title;

  /// Overrides [ArulTokens.screenHeaderTitle] — ONE caller: the feed, whose "Arul" is the WORDMARK.
  /// A title changing size between cross-fading tabs reads as the whole screen jumping.
  /// So never use this to make a tab special — a wordmark is a different object; a title is not.
  final TextStyle? titleStyle;

  /// Optical drop for the title, logical px, positive = down.
  ///
  /// A TRANSLATE -> it moves paint, never the band, so the reel below cannot be pushed around by it.
  /// The layout height stays [ArulTokens.headerControlSize], bounded by the band's spare room.
  final double titleDrop;

  final Widget? leading;

  /// Trailing controls, right-aligned with [_actionGap] between them.
  /// Each MUST be [bandHeight] tall and DRAW [ArulTokens.headerControlSize] inside [bandPadding]
  /// (see [ArulEarnButton]) -> the band is the same height on every tab, and the control is tapped
  /// at Android's 48 while the eye still sees 34.
  final List<Widget> actions;

  /// The band's full height: the control row plus the air either side. 48 — which is also
  /// [ArulTokens.minHitTarget], so an action that spans the band is a real target for free.
  static const double bandHeight =
      ArulTokens.headerTopPadding +
      ArulTokens.headerControlSize +
      ArulTokens.headerBottomPadding;

  /// Where the 34 px visual sits inside the band — the SAME insets the band used to wear as
  /// padding, so nothing moved when the hit box grew.
  static const EdgeInsets bandPadding = EdgeInsets.only(
    top: ArulTokens.headerTopPadding,
    bottom: ArulTokens.headerBottomPadding,
  );

  static const double _leadingGap = 12;

  static const double _actionGap = 8;

  /// **Optical left inset for the title — tune it if the title reads too near the screen edge.**
  ///
  /// Title and button share [ArulTokens.screenPadding] and both touch 15.3dp on device.
  /// The button's 14dp corners curve away over most of its height -> its edge AVERAGES 17.6dp.
  /// The title's leftmost ink is a splayed serif foot -> it averages 20.6dp, touching 15.3 once.
  /// So equal padding does not look equal -> nudge the TEXT only.
  /// A [leading] glyph keeps the true gutter — unlike type it has a real edge.
  static const double _titleOpticalInset = 3;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // The vertical air is INSIDE the band now (leading and title wear it as [bandPadding]) so an
    // action can span the whole 48 and be tapped there; the band's height is unchanged, so the
    // reel solved against it is too.
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: ArulTokens.screenPadding),
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
                  offset: Offset(0, titleDrop),
                  // Shrinks, never clips — the dock's rule, applied to the title: a Malayalam
                  // "Ringtones" at a 1.3 OS font size on a 320 dp phone lost its last letters to an
                  // ellipsis, and a title cut mid-word reads as broken where a slightly smaller one
                  // reads as the title. At every ordinary size the box is wider than the word and
                  // scaleDown is a no-op, so the one type scale still holds across the tabs.
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
