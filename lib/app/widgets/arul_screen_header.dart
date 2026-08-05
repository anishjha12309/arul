import 'package:flutter/material.dart';

import '../../theme/arul_tokens.dart';

/// The one header band every top-level tab wears.
///
/// The three tabs cross-fade into one another (see the shell's branch
/// container), so the title is the thing the eye is anchored on while the
/// content swaps underneath. Three different sizes and three different drops —
/// which is what Wallpapers (24), Ringtones (27) and Settings (22) used to have
/// — made every tab switch read as the whole screen jumping. One band, one type
/// scale, one control height fixes that; a tab that needs something different
/// puts it in [actions], not in the geometry.
///
/// The metrics are the wallpaper feed's, unchanged, and deliberately so: the
/// reel's card geometry is solved from the height left below this band
/// (`feed_screen.dart`), so moving the header would resize the reel.
class ArulScreenHeader extends StatelessWidget {
  const ArulScreenHeader({
    super.key,
    required this.title,
    this.titleStyle,
    this.titleDrop = 0,
    this.leading,
    this.actions = const [],
  });

  /// The screen's name. Rendered in [ArulTokens.screenHeaderTitle] — Marcellus,
  /// so this is Latin-safe brand type; a localized title still renders through
  /// the Noto fallbacks.
  final String title;

  /// Overrides [ArulTokens.screenHeaderTitle]. Exactly ONE caller passes it:
  /// the wallpaper feed, whose "Arul" is the brand WORDMARK rather than a page
  /// title and takes [ArulTokens.wordmarkHeader]. Do not reach for this to make
  /// a tab's title special — the tabs cross-fade, and a title that changes size
  /// between them reads as the whole screen jumping. A wordmark is a different
  /// object; a title is not.
  final TextStyle? titleStyle;

  /// Optical drop for the title, logical px, positive = down.
  ///
  /// A TRANSLATE, so it moves the paint and not the band: the layout height
  /// stays [ArulTokens.headerControlSize] whatever this is, and the reel below
  /// (whose card geometry is solved from that height) cannot be pushed around
  /// by it. Bounded in practice by the band's spare room — see
  /// [ArulTokens.wordmarkHeader].
  final double titleDrop;

  /// Optional glyph before the title (Settings' back arrow). Sized to
  /// [ArulTokens.headerControlSize] by its own widget.
  final Widget? leading;

  /// Trailing controls, laid out right-aligned with [_actionGap] between them.
  /// Each must be [ArulTokens.headerControlSize] tall so the band's height is
  /// the same on every tab.
  final List<Widget> actions;

  /// Gap between the leading glyph and the title.
  static const double _leadingGap = 12;

  /// Gap between two trailing controls.
  static const double _actionGap = 8;

  /// **Optical left inset for the title. Tune this if the title reads too near
  /// the screen edge against the Earn button opposite it.**
  ///
  /// The title and the button sit on the same [ArulTokens.screenPadding], and
  /// measured on device both touch 15.3dp — but neither shows a straight edge.
  /// The button's 14dp corners curve away from the rim over most of its height,
  /// so its edge AVERAGES 17.6dp; the title's leftmost ink is only the splayed
  /// foot of a serif, and it averages 20.6dp with just that one point reaching
  /// 15.3. Equal padding therefore does not look equal.
  ///
  /// This nudges the text only — a [leading] glyph keeps the true gutter,
  /// because unlike type it has a real edge.
  static const double _titleOpticalInset = 3;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        ArulTokens.screenPadding,
        ArulTokens.headerTopPadding,
        ArulTokens.screenPadding,
        ArulTokens.headerBottomPadding,
      ),
      child: SizedBox(
        height: ArulTokens.headerControlSize,
        child: Row(
          children: [
            if (leading != null) ...[
              leading!,
              const SizedBox(width: _leadingGap),
            ],
            // Expanded, not a Spacer: a localized title is half again as long
            // as "Ringtones" and the OS font-size setting is not clamped, so it
            // has to be the thing that gives way.
            Expanded(
              // Two different kinds of nudge, deliberately. The horizontal one
              // is PADDING — it reserves its 3px, so a long localized title
              // ellipsises against the real space it has. The vertical one is a
              // TRANSLATE — it must not add height, or the band grows and the
              // reel below resizes with it.
              child: Padding(
                padding: const EdgeInsets.only(left: _titleOpticalInset),
                child: Transform.translate(
                  offset: Offset(0, titleDrop),
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: (titleStyle ?? ArulTokens.screenHeaderTitle).copyWith(
                      // Gold on dark, not ivory: the handoff sets the wordmark
                      // in the brand accent so the header reads as brand rather
                      // than as a page label. Light keeps its ink — gold on
                      // ivory has nothing to carry it.
                      color: isDark ? ArulTokens.gold : ArulTokens.lightText,
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
