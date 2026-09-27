import 'package:flutter/material.dart';

import '../../theme/arul_tokens.dart';
import 'arul_icon_tap.dart';

class ArulPushedHeader extends StatelessWidget {
  const ArulPushedHeader({
    super.key,
    required this.title,
    required this.color,
    this.onBack,
    this.identifier,
  });

  final String title;

  final Color color;

  final VoidCallback? onBack;

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
