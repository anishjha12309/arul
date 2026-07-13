import 'package:flutter/material.dart';

import '../../../app/l10n/app_localizations.dart';
import '../../../app/theme/tokens.dart';

/// What premium actually buys. Kept to four lines: a paywall that lists ten
/// things is a paywall nobody reads.
class PremiumBenefits extends StatelessWidget {
  const PremiumBenefits({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      children: [
        _Benefit(text: l10n.premiumBenefitApply),
        _Benefit(text: l10n.premiumBenefitLive),
        _Benefit(text: l10n.premiumBenefitShare),
        _Benefit(text: l10n.premiumBenefitNew),
      ],
    );
  }
}

class _Benefit extends StatelessWidget {
  const _Benefit({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.lg),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.check_circle_rounded,
            size: 20,
            color: ArulColors.gold,
          ),
          const SizedBox(width: Gap.md),
          Expanded(
            child: Text(
              text,
              style: Theme.of(
                context,
              ).textTheme.bodyLarge?.copyWith(color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }
}
