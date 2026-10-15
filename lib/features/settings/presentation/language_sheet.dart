import 'package:flutter/material.dart';

import '../../../app/l10n/app_localizations.dart';
import '../../../app/widgets/arul_pressable.dart';
import '../../../app/widgets/arul_sheet.dart';
import '../../../core/haptics/arul_haptics.dart';
import '../../../core/providers/locale_provider.dart';
import '../../../theme/arul_palette.dart';
import '../../../theme/arul_tokens.dart';

/// One row: the native label over the English name. Both come from `locale_provider.dart`, the one
/// home for the language tables -> the sheet, Settings and the sign-in trigger cannot drift apart.
class _Lang {
  const _Lang(this.native, this.name);
  final String native;
  final String name;
}

/// The sheet only RESOLVES the choice and applies nothing — it returns the chosen English name.
/// The caller persists it and drives the app locale from it. [only] narrows the tiles to those
/// language codes (Status offers only the languages it has clips in); null [current] selects none.
Future<String?> showLanguageSheet(
  BuildContext context,
  String? current, {
  Brightness? brightness,
  List<String>? only,
}) {
  final langs = <_Lang>[
    for (final locale in supportedAppLocales)
      if (only == null || only.contains(locale.languageCode))
        _Lang(
          appLanguageNativeName(locale.languageCode),
          appLanguageName(locale.languageCode),
        ),
  ];
  return showArulSheet<String>(
    context,
    brightness: brightness,
    builder: (_) => _LanguageSheet(current: current, langs: langs),
  );
}

class _LanguageSheet extends StatelessWidget {
  const _LanguageSheet({required this.current, required this.langs});

  final String? current;
  final List<_Lang> langs;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 26),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            AppLocalizations.of(context).settingsLanguage,
            style: ArulTokens.sheetTitle.copyWith(
              color: ArulPalette.of(context).text,
            ),
          ),
          const SizedBox(height: 14),
          // Height comes from the CONTENT, never from the width.
          // The text half scales with the user's text size; the 32dp of padding does not.
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: langs.length,
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              // 45dp is what the tallest pairing actually measures (Devanagari 17px over a 12px
              // caption); 48 leaves the slack that stops a one-pixel stripe. 32 is the padding.
              mainAxisExtent: MediaQuery.textScalerOf(context).scale(48) + 32,
            ),
            itemBuilder: (_, i) {
              final l = langs[i];
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
    final p = ArulPalette.of(context);

    // The reference sheet is dark-only -> the light unselected tile is an assumption: white, maroon.
    // Selected is gold in both themes, per spec.
    final bg = on ? ArulTokens.goldTintFill14 : p.card;
    final border = on ? ArulTokens.gold : p.border;
    final nativeColor = on ? p.goldInk : p.text;

    return ArulPressable(
      semanticLabel: '${lang.native} ${lang.name}',
      selected: on,
      // A language tile picks between discrete values — the same tick as theme rows and chips.
      haptic: ArulHapticStyle.selection,
      onTap: onTap,
      builder: (context, pressed) => Container(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
        decoration: BoxDecoration(
          color: pressed ? Color.alphaBlend(p.accentTint, bg) : bg,
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
              style: ArulTokens.caption.copyWith(color: p.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}
