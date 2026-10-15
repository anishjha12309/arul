import 'package:flutter/material.dart';

import '../../theme/arul_palette.dart';
import '../../theme/arul_tokens.dart';
import 'arul_icon_tap.dart';

/// The one header band every top-level tab wears.
class ArulScreenHeader extends StatelessWidget {
  const ArulScreenHeader({
    super.key,
    required this.title,
    this.fallbackTitle,
    this.leading,
    this.actions = const [],
  });

  final String title;

  /// The English title, shown whole when the localized [title] does not fit; a translation never shrinks.
  final String? fallbackTitle;

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

  // Indic letters fall back to the system Noto, whose ink sits off the Cinzel caps' centre.
  // Per script: its three tab titles' mean ink offset from English (under 1 dp left out), in ems
  // of the 24 dp title -> the drop follows a size change in the token.
  static const _scriptDropEm = <String, double>{
    'hi': 2.0 / 24,
    'ml': -1.0 / 24,
    'ta': -1.5 / 24,
  };

  @override
  Widget build(BuildContext context) {
    final p = ArulPalette.of(context);

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
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final style = ArulTokens.screenHeaderTitle.copyWith(
                      // Gold on dark, not ivory -> the header reads as brand, not as a page
                      // label. Light keeps its ink — gold on ivory has nothing to carry it.
                      color: p.chromeInk,
                    );
                    final english = fallbackTitle;
                    final localized =
                        english == null ||
                        _fits(context, title, style, constraints.maxWidth);
                    return Transform.translate(
                      offset: Offset(
                        0,
                        localized
                            ? (_scriptDropEm[Localizations.localeOf(
                                        context,
                                      ).languageCode] ??
                                      0) *
                                  ArulTokens.screenHeaderTitle.fontSize!
                            : 0,
                      ),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        // A too-wide translation was swapped for English above -> only English is ever
                        // narrowed. Past ~1.2x OS text the band's height caps every language alike.
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: Text(
                            localized ? title : english,
                            maxLines: 1,
                            style: style,
                          ),
                        ),
                      ),
                    );
                  },
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

  static bool _fits(
    BuildContext context,
    String text,
    TextStyle style,
    double room,
  ) {
    var effective = DefaultTextStyle.of(context).style.merge(style);
    // [Text] applies the OS bold-text setting the same way -> measure what it paints.
    if (MediaQuery.boldTextOf(context)) {
      effective = effective.merge(const TextStyle(fontWeight: FontWeight.bold));
    }
    final painter = TextPainter(
      text: TextSpan(text: text, style: effective),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final fits = painter.width <= room;
    painter.dispose();
    return fits;
  }
}
