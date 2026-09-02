import 'package:flutter/material.dart';

import '../../theme/arul_tokens.dart';
import 'arul_screen_header.dart';

/// The whole upper portion of a browse tab, as one piece: title band, chip row, and the air beneath.
///
/// Assembling it per tab drifted: the feed grew a hairline the ringtone list lacked -> the row moved.
/// The tabs cross-fade rather than cut -> the eye catches exactly that kind of shift.
/// So the frame lives here and the tabs supply only [chips] -> spacing is never per-screen.
/// **There is no rule under the chips** (owner's call) — it read as a seam on an unbroken screen.
/// The card's own edge marks the reel's clip line well enough -> do not re-add one.
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

  /// Passed straight through to [ArulScreenHeader.titleStyle] — read its doc first. Only the feed calls it.
  final TextStyle? titleStyle;

  /// Passed straight through to [ArulScreenHeader.titleDrop].
  final double titleDrop;

  /// The category chip row. Each tab reads its own catalog -> only this differs, never the frame.
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
        // 8 above the chip row against 33 below left it riding high in its own band, on both tabs.
        // [ArulTokens.chipsTopGap] tops the 8 up to the bottom's number -> the row sits in EQUAL air.
        const SizedBox(height: ArulTokens.chipsTopGap),
        // Chips get the FULL width — nothing overlaps them.
        chips,
        const SizedBox(height: ArulTokens.chipsBottomGap),
      ],
    );
  }
}
