import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/l10n/app_localizations.dart';
import '../../../app/theme/tokens.dart';
import '../providers/theme_mode_provider.dart';

/// Section heading — wide-tracked uppercase, the one typographic move that reads
/// "considered" for free.
class SettingsSection extends StatelessWidget {
  const SettingsSection({super.key, required this.title});

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.xl, Gap.lg, Gap.sm),
    child: Text(
      title.toUpperCase(),
      style: Theme.of(context).textTheme.labelSmall,
    ),
  );
}

/// Light / Dark / System. Persisted; never seeded from the device wallpaper.
class ThemeModePicker extends ConsumerWidget {
  const ThemeModePicker({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final mode = ref.watch(themeModeProvider);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
      child: SegmentedButton<ThemeMode>(
        segments: [
          ButtonSegment(value: ThemeMode.system, label: Text(l10n.themeSystem)),
          ButtonSegment(value: ThemeMode.light, label: Text(l10n.themeLight)),
          ButtonSegment(value: ThemeMode.dark, label: Text(l10n.themeDark)),
        ],
        selected: {mode},
        showSelectedIcon: false,
        onSelectionChanged: (s) =>
            ref.read(themeModeProvider.notifier).select(s.first),
      ),
    );
  }
}
