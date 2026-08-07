import 'package:flutter/material.dart';

import '../../../app/l10n/app_localizations.dart';
import '../../../app/widgets/arul_sheet.dart';
import '../../../core/haptics/arul_haptics.dart';
import '../../../theme/arul_tokens.dart';

/// The six languages, native label over English name. Order and glyphs are
/// verbatim per spec: English / தமிழ் / తెలుగు / ಕನ್ನಡ / മലയാളം / हिन्दी.
class _Lang {
  const _Lang(this.native, this.name);
  final String native;
  final String name;
}

const _langs = <_Lang>[
  _Lang('English', 'English'),
  _Lang('தமிழ்', 'Tamil'),
  _Lang('తెలుగు', 'Telugu'),
  _Lang('ಕನ್ನಡ', 'Kannada'),
  _Lang('മലയാളം', 'Malayalam'),
  _Lang('हिन्दी', 'Hindi'),
];

/// The language picker sheet — spec: "Bottom sheet 'Language'; 2-col grid gap
/// 10, 6 tiles (r16, 16/8 pad, centered): native 17px/600 over English 12px.
/// Selected: gold 1.5px border + gold-tint bg + gold native text."
///
/// The sheet only RESOLVES the choice — it applies nothing itself: it returns
/// the chosen English name, and the caller persists it and drives the app
/// locale from it.
Future<String?> showLanguageSheet(BuildContext context, String current) {
  return showArulSheet<String>(
    context,
    builder: (_) => _LanguageSheet(current: current),
  );
}

class _LanguageSheet extends StatelessWidget {
  const _LanguageSheet({required this.current});

  final String current;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final titleColor = isDark ? ArulTokens.darkText : ArulTokens.lightText;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 26),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            AppLocalizations.of(context).settingsLanguage,
            style: ArulTokens.sheetTitle.copyWith(color: titleColor),
          ),
          const SizedBox(height: 14),
          GridView.count(
            crossAxisCount: 2,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 165 / 74, // tile ≈ 165×74 on a 428-wide frame
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            children: [
              for (final l in _langs)
                _LangTile(
                  lang: l,
                  on: l.name == current,
                  onTap: () => Navigator.of(context).pop(l.name),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _LangTile extends StatelessWidget {
  const _LangTile({required this.lang, required this.on, required this.onTap});

  final _Lang lang;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Unselected surfaces mirror the dark reference; the light equivalents are an
    // ASSUMPTION (the reference language sheet is dark-only) — white tile, maroon
    // hairline. Selected is gold in both themes per spec.
    final Color bg = on
        ? ArulTokens.goldTintFill14
        : (isDark ? ArulTokens.cardBgDark04 : ArulTokens.cardBgLight);
    final Color border = on
        ? ArulTokens.gold
        : (isDark ? ArulTokens.cardBorderDark14 : ArulTokens.cardBorderLight);
    final Color nativeColor = on
        ? ArulTokens.gold
        : (isDark ? ArulTokens.darkText : ArulTokens.lightText);
    final Color nameColor = isDark
        ? ArulTokens.darkTextSecondary
        : ArulTokens.lightSecondary;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // A language tile picks between discrete values — same tick as the theme
      // rows and the category chips.
      onTapDown: (_) => ArulHaptics.selection(),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
        decoration: BoxDecoration(
          color: bg,
          border: Border.all(color: border, width: 1.5),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              lang.native,
              textAlign: TextAlign.center,
              // sheetTitle is 17px/w600 (system stack — safe for Indic glyphs).
              style: ArulTokens.sheetTitle.copyWith(color: nativeColor),
            ),
            const SizedBox(height: 3),
            Text(
              lang.name,
              textAlign: TextAlign.center,
              style: ArulTokens.caption.copyWith(color: nameColor),
            ),
          ],
        ),
      ),
    );
  }
}
