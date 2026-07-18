import 'package:flutter/material.dart';

import '../../../app/widgets/arul_sheet.dart';
import '../../../app/widgets/cta_button.dart';
import '../../../theme/arul_tokens.dart';
import '../data/wallpaper_apply_service.dart';

/// Where to put a STATIC wallpaper (README > Apply sheet).
///
/// Three equal cards — Home screen / Lock screen / Both (default Both) — and a
/// single green CTA. Selecting a card only moves the selection; the CTA commits
/// the chosen target. Live wallpapers never reach here: Android's own
/// live-wallpaper chooser asks the same question and is the one that decides.
///
/// Keeps the `ApplySheet.show(context) → Future<ApplyTarget?>` contract: the
/// future resolves to the picked target, or null if the sheet is dismissed.
class ApplySheet {
  const ApplySheet._();

  static Future<ApplyTarget?> show(BuildContext context) {
    return showArulSheet<ApplyTarget>(
      context,
      builder: (_) => const _ApplySheetBody(),
    );
  }
}

class _ApplySheetBody extends StatefulWidget {
  const _ApplySheetBody();

  @override
  State<_ApplySheetBody> createState() => _ApplySheetBodyState();
}

class _ApplySheetBodyState extends State<_ApplySheetBody> {
  ApplyTarget _target = ApplyTarget.both; // README: default Both

  static const _cards = <(ApplyTarget, IconData, String)>[
    (ApplyTarget.home, Icons.home_rounded, 'Home screen'),
    (ApplyTarget.lock, Icons.lock_rounded, 'Lock screen'),
    (ApplyTarget.both, Icons.smartphone_rounded, 'Both'),
  ];

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      // README: pad 18 20 24; the grabber + its padding come from ArulSheet.
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Set wallpaper on',
            style: ArulTokens.sheetTitle.copyWith(
              color: isDark ? ArulTokens.darkText : ArulTokens.lightText,
            ),
          ),
          const SizedBox(height: 16),

          Row(
            children: [
              for (var i = 0; i < _cards.length; i++) ...[
                if (i > 0) const SizedBox(width: 10),
                Expanded(
                  child: _TargetCard(
                    icon: _cards[i].$2,
                    label: _cards[i].$3,
                    selected: _target == _cards[i].$1,
                    onTap: () => setState(() => _target = _cards[i].$1),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 16),

          CtaButton(
            label: 'Apply wallpaper',
            icon: Icons.wallpaper_rounded,
            height: ArulTokens.ctaHeight50,
            fontSize: 15.5,
            onPressed: () => Navigator.of(context).pop(_target),
          ),
        ],
      ),
    );
  }
}

/// One target card (README > Apply sheet): r16, 26px icon + 13px label.
/// Selected: gold 1.5px border, gold-tint fill, gold icon (both themes).
/// Unselected follows the app theme — ivory-tint on dark, maroon-tint on light.
class _TargetCard extends StatelessWidget {
  const _TargetCard({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final unselectedFill = isDark
        ? ArulTokens.cardBgDark05
        : ArulTokens.maroonTintFill07;
    final unselectedBorder = isDark
        ? ArulTokens.cardBorderDark14
        : ArulTokens.cardBorderLight;
    final unselectedIcon = isDark
        ? ArulTokens.ivory
        : ArulTokens.lightSecondary;
    final labelColor = isDark ? ArulTokens.darkText : ArulTokens.lightText;

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.fromLTRB(8, 16, 8, 13),
        decoration: BoxDecoration(
          color: selected ? ArulTokens.goldTintFill14 : unselectedFill,
          borderRadius: BorderRadius.circular(ArulTokens.iconChipRadius + 4),
          border: Border.all(
            color: selected ? ArulTokens.gold : unselectedBorder,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 26,
              color: selected ? ArulTokens.gold : unselectedIcon,
            ),
            const SizedBox(height: 8),
            Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: labelColor,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
