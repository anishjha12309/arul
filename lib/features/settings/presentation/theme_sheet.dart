import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/l10n/app_localizations.dart';
import '../../../app/widgets/arul_sheet.dart';
import '../../../core/haptics/arul_haptics.dart';
import '../../../theme/arul_tokens.dart';
import '../providers/theme_mode_provider.dart';

/// The theme picker sheet, laid out to the mock's spec.
///
/// FUNCTIONAL, not a mock -> a row drives [themeModeProvider] (real switching), then closes.
Future<void> showThemeSheet(BuildContext context) {
  return showArulSheet<void>(
    context,
    // The gold edge reads as a stray line on a sheet this small -> off here.
    topHairline: false,
    builder: (_) => const _ThemeSheet(),
  );
}

/// Human label for a [ThemeMode], used both here and for the settings row sub.
String themeModeLabel(AppLocalizations l10n, ThemeMode mode) => switch (mode) {
  ThemeMode.system => l10n.themeSystemDefault,
  ThemeMode.light => l10n.themeLight,
  ThemeMode.dark => l10n.themeDark,
};

/// Glyph for a [ThemeMode] — the ONE mapping, read by the sheet's own options and by the Settings
/// row that opens it.
///
/// The glyph is what the eye checks first in a list of rows -> a row with its own hardcoded icon
/// shows a crescent moon beside a "Light" sub-label -> both sites read THIS.
IconData themeModeIcon(ThemeMode mode) => switch (mode) {
  // "Follow the device" is a rule, not a brightness -> a gear, never a sun-and-moon composite.
  ThemeMode.system => Icons.settings_suggest,
  ThemeMode.light => Icons.light_mode,
  ThemeMode.dark => Icons.dark_mode,
};

class _ThemeOption {
  const _ThemeOption(this.mode, this.title, this.sub);
  final ThemeMode mode;
  final String title;
  final String sub;

  IconData get icon => themeModeIcon(mode);
}

List<_ThemeOption> _options(AppLocalizations l10n) => <_ThemeOption>[
  _ThemeOption(ThemeMode.system, l10n.themeSystemDefault, l10n.themeSystemSub),
  _ThemeOption(ThemeMode.light, l10n.themeLight, l10n.themeLightSub),
  _ThemeOption(ThemeMode.dark, l10n.themeDark, l10n.themeDarkSub),
];

class _ThemeSheet extends ConsumerWidget {
  const _ThemeSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final selected = ref.watch(themeModeProvider);
    final titleColor = isDark ? ArulTokens.darkText : ArulTokens.lightText;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 26),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.settingsTheme,
            style: ArulTokens.sheetTitle.copyWith(color: titleColor),
          ),
          const SizedBox(height: 14),
          for (final (i, o) in _options(l10n).indexed) ...[
            if (i > 0) const SizedBox(height: kSheetRowGap),
            ArulSheetRow(
              icon: o.icon,
              title: o.title,
              sub: o.sub,
              selected: selected == o.mode,
              // Picking a theme moves between discrete values -> it ticks, not presses.
              haptic: ArulHapticStyle.selection,
              // Flip the theme and close in the SAME frame -> the sheet slides away already wearing
              // the new theme.
              // `select` applies the mode synchronously and only THEN awaits the prefs write ->
              // awaiting it here parks the pop behind a disk round-trip, which reads as a stutter ->
              // fire-and-forget; nothing on screen waits on the write.
              onTap: () {
                unawaited(ref.read(themeModeProvider.notifier).select(o.mode));
                Navigator.of(context).pop();
              },
            ),
          ],
        ],
      ),
    );
  }
}
