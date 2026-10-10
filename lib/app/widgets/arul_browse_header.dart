import 'package:flutter/material.dart';

import '../../theme/arul_tokens.dart';
import 'arul_screen_header.dart';

/// The whole upper portion of a browse tab, as one piece: title band, chip row, and the air beneath.
/// The tabs cross-fade rather than cut -> the eye catches exactly that kind of shift.
/// So the frame lives here and the tabs supply only [chips] -> spacing is never per-screen.
class ArulBrowseHeader extends StatelessWidget {
  const ArulBrowseHeader({
    super.key,
    required this.title,
    required this.chips,
    this.titleStyle,
    this.titleDrop = 0,
    this.actions = const [],
    this.chipsReveal,
  });

  final String title;

  /// Passed straight through to [ArulScreenHeader.titleStyle] — read its doc first. Only the feed calls it.
  final TextStyle? titleStyle;

  final double titleDrop;

  /// The category chip row. Each tab reads its own catalog -> only this differs, never the frame.
  final Widget chips;

  final List<Widget> actions;

  /// Folds the chip row and the air above it away at 0 -> the tab below gets that height.
  final Animation<double>? chipsReveal;

  @override
  Widget build(BuildContext context) {
    final row = Column(
      children: [
        // 8 above the chip row against 33 below left it riding high in its own band, on both tabs.
        // [ArulTokens.chipsTopGap] tops the 8 up to the bottom's number -> the row sits in EQUAL air.
        const SizedBox(height: ArulTokens.chipsTopGap),
        chips,
      ],
    );
    final reveal = chipsReveal;
    return Column(
      children: [
        ArulScreenHeader(
          title: title,
          titleStyle: titleStyle,
          titleDrop: titleDrop,
          actions: actions,
        ),
        if (reveal == null)
          row
        else
          SizeTransition(
            sizeFactor: reveal,
            alignment: Alignment.topCenter,
            child: FadeTransition(opacity: reveal, child: row),
          ),
        const SizedBox(height: ArulTokens.chipsBottomGap),
      ],
    );
  }
}
