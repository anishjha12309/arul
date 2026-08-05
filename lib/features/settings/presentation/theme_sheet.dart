import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/widgets/arul_sheet.dart';
import '../../../core/haptics/arul_haptics.dart';
import '../../../theme/arul_tokens.dart';
import '../providers/theme_mode_provider.dart';

/// The theme picker sheet — spec: "Bottom sheet 'Theme'; 3 rows (r14, 12px
/// pad): System default / Light / Dark. Selected: gold-tint bg, gold icon+title,
/// gold check_circle." This one is FUNCTIONAL: selecting a row drives
/// [themeModeProvider] (real theme switching), then closes the sheet.
Future<void> showThemeSheet(BuildContext context) {
  return showArulSheet<void>(
    context,
    // The gold edge reads as a stray line over this small sheet — off here.
    topHairline: false,
    builder: (_) => const _ThemeSheet(),
  );
}

/// Human label for a [ThemeMode], used both here and for the settings row sub.
String themeModeLabel(ThemeMode mode) => switch (mode) {
  ThemeMode.system => 'System default',
  ThemeMode.light => 'Light',
  ThemeMode.dark => 'Dark',
};

/// Glyph for a [ThemeMode] — the ONE mapping, read by the sheet's own options
/// and by the Settings row that opens it.
///
/// The row used to hardcode [Icons.dark_mode], so it sat there showing a
/// crescent moon while its own sub-label read "Light": the glyph is the thing
/// the eye checks first in a list of rows, and it was the one part of the row
/// that never moved. It answers to the selection now, and because the sheet
/// reads the same function the row's icon is always the chosen option's icon.
IconData themeModeIcon(ThemeMode mode) => switch (mode) {
  // Not a sun-and-moon composite: "follow the device" is a rule, not a
  // brightness, and the sheet has always drawn it as one.
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

const _options = <_ThemeOption>[
  _ThemeOption(ThemeMode.system, 'System default', 'Follow device setting'),
  _ThemeOption(ThemeMode.light, 'Light', 'Ivory & silk'),
  _ThemeOption(ThemeMode.dark, 'Dark', 'Lamp-lit maroon'),
];

class _ThemeSheet extends ConsumerWidget {
  const _ThemeSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
            'Theme',
            style: ArulTokens.sheetTitle.copyWith(color: titleColor),
          ),
          const SizedBox(height: 12),
          for (final o in _options)
            _ThemeRow(
              option: o,
              on: selected == o.mode,
              // Flip the theme and close in the SAME frame, so the sheet slides
              // away already wearing the new theme.
              //
              // `select` applies the mode synchronously and only then awaits the
              // SharedPreferences write, so awaiting it here parked the pop
              // behind a disk round-trip: the theme changed, the sheet sat there
              // for however long the write took, and only then began to dismiss.
              // That gap is what made the switch feel like it stuttered. The
              // write is fire-and-forget — nothing on screen is waiting on it.
              onTap: () {
                unawaited(ref.read(themeModeProvider.notifier).select(o.mode));
                Navigator.of(context).pop();
              },
            ),
        ],
      ),
    );
  }
}

class _ThemeRow extends StatelessWidget {
  const _ThemeRow({
    required this.option,
    required this.on,
    required this.onTap,
  });

  final _ThemeOption option;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final unselectedIcon = isDark
        ? ArulTokens.darkTextSecondary
        : ArulTokens.lightSecondary;
    final unselectedTitle = isDark ? ArulTokens.darkText : ArulTokens.lightText;
    final subColor = isDark
        ? ArulTokens.darkTextSecondary
        : ArulTokens.lightSecondary;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // Picking a theme moves between discrete values, so it ticks rather than
      // presses — same beat as a radio or a chip.
      onTapDown: (_) => ArulHaptics.selection(),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: on ? ArulTokens.goldTintFill10 : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Icon(
              option.icon,
              size: 22,
              color: on ? ArulTokens.gold : unselectedIcon,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    option.title,
                    style: ArulTokens.rowTitle.copyWith(
                      color: on ? ArulTokens.gold : unselectedTitle,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    option.sub,
                    style: ArulTokens.rowSub.copyWith(color: subColor),
                  ),
                ],
              ),
            ),
            if (on)
              const Icon(Icons.check_circle, size: 20, color: ArulTokens.gold),
          ],
        ),
      ),
    );
  }
}
