import 'package:flutter/material.dart';

import '../../theme/arul_tokens.dart';
import 'arul_icon_tap.dart';

/// The header every pushed screen wears (Reminders, Refer, Upload): a back arrow and the screen's
/// title, in ONE geometry.
///
/// Three hand-built copies drifted — a Material `IconButton` here, a bare glyph there, gaps of 4
/// and 12 — so the arrow and the title jumped sideways between screens. The arrow is an
/// [ArulIconTap]: 48 dp, named with Material's own back label, a haptic on press-down. The left
/// padding is `screenPadding - slack` so the glyph's ink sits on the same 16 dp gutter as the
/// tabs' titles, and the title shrinks before it clips (the dock's rule).
class ArulPushedHeader extends StatelessWidget {
  const ArulPushedHeader({
    super.key,
    required this.title,
    required this.color,
    this.onBack,
    this.identifier,
  });

  final String title;

  /// Ink for both the arrow and the title.
  final Color color;

  /// Defaults to popping the route.
  final VoidCallback? onBack;

  /// Stable accessibility id for the back control (`Semantics(identifier:)`).
  final String? identifier;

  static const double _glyph = 24;

  @override
  Widget build(BuildContext context) {
    final slack = ArulIconTap.slackFor(_glyph);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        ArulTokens.screenPadding - slack,
        2,
        ArulTokens.screenPadding,
        10,
      ),
      child: Row(
        children: [
          ArulIconTap(
            icon: Icons.arrow_back,
            size: _glyph,
            color: color,
            label: MaterialLocalizations.of(context).backButtonTooltip,
            identifier: identifier,
            onTap: onBack ?? () => Navigator.of(context).maybePop(),
          ),
          Expanded(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                title,
                maxLines: 1,
                style: ArulTokens.screenTitle.copyWith(color: color),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
