import 'package:flutter/material.dart';

import '../../theme/arul_tokens.dart';
import 'arul_screen_header.dart';

/// The whole upper portion of a browse tab, as one piece: title band, category
/// chip row, and the air the content begins beneath.
///
/// Wallpapers and Ringtones are the same screen with different cargo — a title,
/// a row of category pills, then content. Assembling that separately in each
/// meant they drifted: the feed once grew a hairline the ringtone list never
/// had, so switching tabs moved the first row by the height of a rule plus its
/// gaps. Because the tabs cross-fade rather than cut, that shift is exactly the
/// kind the eye catches.
///
/// So the frame lives here and the tabs supply only [chips]. Nothing about the
/// spacing is per-screen; if it needs to change, it changes for both.
///
/// **There is no rule under the chips** (removed 2026-08-06, owner's call). It
/// used to mark the reel's clip line — the one place an outgoing card can
/// vanish — but it read as a seam across a screen that is otherwise unbroken,
/// and the card's own edge marks that line well enough. Do not re-add it.
class ArulBrowseHeader extends StatelessWidget {
  const ArulBrowseHeader({
    super.key,
    required this.title,
    required this.chips,
    this.titleStyle,
    this.titleDrop = 0,
    this.actions = const [],
  });

  /// The screen's name, rendered by [ArulScreenHeader].
  final String title;

  /// Passed straight through to [ArulScreenHeader.titleStyle] — read its doc
  /// before using it. The wallpaper feed is the only caller.
  final TextStyle? titleStyle;

  /// Passed straight through to [ArulScreenHeader.titleDrop].
  final double titleDrop;

  /// The category chip row. Each tab reads its own catalog, so only this part
  /// differs — the frame around it does not.
  final Widget chips;

  /// Trailing controls in the title band (Earn, refer, settings).
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ArulScreenHeader(
          title: title,
          titleStyle: titleStyle,
          titleDrop: titleDrop,
          actions: actions,
        ),
        // The chip row sits in EQUAL air. The title band only ever left
        // `headerBottomPadding` (8) above it while the drop to the content
        // below was 33, so the row rode high in its own band on both tabs;
        // these two gaps now match ([ArulTokens.chipsTopGap] tops the 8 up to
        // the same number the bottom uses).
        const SizedBox(height: ArulTokens.chipsTopGap),
        // Chips get the FULL width — nothing overlaps them.
        chips,
        // Air, no rule. A hairline used to sit in this gap on both tabs; the
        // handoff does not draw one and it read as a seam across a screen that
        // is otherwise unbroken.
        const SizedBox(height: ArulTokens.chipsBottomGap),
      ],
    );
  }
}
