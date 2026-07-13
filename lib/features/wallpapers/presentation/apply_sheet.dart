import 'package:flutter/material.dart';

import '../../../app/l10n/app_localizations.dart';
import '../../../app/theme/tokens.dart';
import '../data/wallpaper_apply_service.dart';

/// Where to put it. Three rows, and **tapping a row commits** — there is no
/// separate confirm button, matching the system share sheet's convention. Apply
/// is therefore two taps, which beats the platform's own wallpaper flow.
///
/// STATIC ONLY. A live wallpaper never reaches this sheet: Android's own
/// live-wallpaper chooser asks the same home/lock/both question and is the one
/// that actually decides, so showing this first asked the user twice and honoured
/// the answer neither time. Live apply goes straight to the chooser.
class ApplySheet extends StatelessWidget {
  const ApplySheet._();

  static Future<ApplyTarget?> show(BuildContext context) {
    return showModalBottomSheet<ApplyTarget>(
      context: context,
      showDragHandle: true,
      // No BackdropFilter blur behind the sheet: it costs 6-9ms of raster per
      // frame on the budget SoCs this app targets, and a video may still be
      // decoding underneath. The scrim is an ordinary paint.
      builder: (_) => const ApplySheet._(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.only(bottom: Gap.md),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.md),
              child: Text(
                l10n.applyTargetTitle,
                style: theme.textTheme.titleMedium,
              ),
            ),
            _TargetRow(
              icon: Icons.home_outlined,
              label: l10n.applyTargetHome,
              onTap: () => Navigator.of(context).pop(ApplyTarget.home),
            ),
            _TargetRow(
              icon: Icons.lock_outline_rounded,
              label: l10n.applyTargetLock,
              onTap: () => Navigator.of(context).pop(ApplyTarget.lock),
            ),
            _TargetRow(
              icon: Icons.smartphone_rounded,
              label: l10n.applyTargetBoth,
              onTap: () => Navigator.of(context).pop(ApplyTarget.both),
            ),
          ],
        ),
      ),
    );
  }
}

class _TargetRow extends StatelessWidget {
  const _TargetRow({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon),
      title: Text(label),
      // No trailing chevron: the row IS the button, and a chevron would imply it
      // opens something further.
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: Gap.lg),
    );
  }
}
