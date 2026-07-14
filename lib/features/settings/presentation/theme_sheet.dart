import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/widgets/arul_sheet.dart';
import '../../../theme/arul_tokens.dart';
import '../providers/theme_mode_provider.dart';

/// The theme picker sheet — README: "Bottom sheet 'Theme'; 3 rows (r14, 12px
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

class _ThemeOption {
  const _ThemeOption(this.mode, this.icon, this.title, this.sub);
  final ThemeMode mode;
  final IconData icon;
  final String title;
  final String sub;
}

const _options = <_ThemeOption>[
  _ThemeOption(
    ThemeMode.system,
    Icons.settings_suggest,
    'System default',
    'Follow device setting',
  ),
  _ThemeOption(ThemeMode.light, Icons.light_mode, 'Light', 'Ivory & silk'),
  _ThemeOption(ThemeMode.dark, Icons.dark_mode, 'Dark', 'Lamp-lit maroon'),
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
              onTap: () async {
                await ref.read(themeModeProvider.notifier).select(o.mode);
                if (context.mounted) Navigator.of(context).pop();
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
