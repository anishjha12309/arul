import 'package:flutter/material.dart';

import '../../../app/l10n/app_localizations.dart';
import '../../../app/widgets/arul_sheet.dart';
import '../../../core/haptics/arul_haptics.dart';
import '../../../theme/arul_tokens.dart';

/// The six languages, native label over English name — order and glyphs verbatim per spec.
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

/// The language picker sheet — 2-column grid, gap 10, six r16 tiles, native 17px over English 12px.
/// Selected is a gold 1.5px border, gold-tint ground and gold native text.
///
/// The sheet only RESOLVES the choice and applies nothing — it returns the chosen English name.
/// The caller persists it and drives the app locale from it.
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
          // Height comes from the CONTENT, never from the width.
          //
          // This was `childAspectRatio: 165 / 74`, measured on a 428dp frame. On the 360dp screen
          // that is 54% of installs the same ratio yields a ~69dp tile, and the tile needs 74:
          // Devanagari and the Indic scripts set taller than Latin at the same 17px, so "हिन्दी"
          // over its caption overflowed the Column by 7.5px on the single most common phone.
          // A ratio also shrinks the tile as the phone narrows, which is exactly backwards.
          //
          // The text half scales with the user's text size; the 32dp of padding does not.
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: _langs.length,
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              // 45dp is what the tallest pairing actually measures (Devanagari 17px over a 12px
              // caption); 48 leaves the slack that stops a one-pixel stripe. 32 is the padding.
              mainAxisExtent: MediaQuery.textScalerOf(context).scale(48) + 32,
            ),
            itemBuilder: (_, i) {
              final l = _langs[i];
              return _LangTile(
                lang: l,
                on: l.name == current,
                onTap: () => Navigator.of(context).pop(l.name),
              );
            },
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

    // The reference sheet is dark-only -> the light unselected tile is an assumption: white, maroon.
    // Selected is gold in both themes, per spec.
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
      // A language tile picks between discrete values — the same tick as theme rows and chips.
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
