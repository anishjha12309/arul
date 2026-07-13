import 'package:flutter/material.dart';

import '../../../app/l10n/app_localizations.dart';
import '../../../app/theme/tokens.dart';
import '../../../app/widgets/arul_button.dart';
import '../../../app/widgets/arul_toast.dart';

/// Price, CTA, and the trial caveat — pinned to the bottom so the commit action
/// is reachable without scrolling, whatever the locale does to the copy above.
class PremiumFooter extends StatelessWidget {
  const PremiumFooter({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.xl, 0, Gap.xl, Gap.xl),
      child: Column(
        children: [
          Text(
            l10n.premiumPrice,
            style: theme.textTheme.titleLarge?.copyWith(
              color: ArulColors.goldSoft,
            ),
          ),
          const SizedBox(height: Gap.md),
          ArulButton(
            label: l10n.premiumCta,
            // TODO(phase-4): PhonePe Autopay mandate via the Worker.
            onPressed: () => showArulToast(context, l10n.premiumComingSoon),
          ),
          const SizedBox(height: Gap.md),
          Text(
            l10n.premiumTrialNote,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: Colors.white.withValues(alpha: 0.5),
            ),
          ),
        ],
      ),
    );
  }
}
