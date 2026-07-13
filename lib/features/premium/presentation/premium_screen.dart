import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/l10n/app_localizations.dart';
import '../../../app/theme/scrims.dart';
import '../../../app/theme/tokens.dart';
import 'premium_benefits.dart';
import 'premium_footer.dart';

/// Paywall. Reached only from a blocked gated action; `source` says which — the
/// one number that tells you which verb actually sells the product.
class PremiumScreen extends ConsumerWidget {
  const PremiumScreen({super.key, required this.source});

  final String source;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);

    return Scaffold(
      body: DecoratedBox(
        decoration: const BoxDecoration(gradient: ArulScrims.silk),
        child: SafeArea(
          child: Column(
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: IconButton(
                  onPressed: () => context.pop(),
                  icon: const Icon(Icons.close_rounded),
                  color: Colors.white,
                  tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.symmetric(horizontal: Gap.xl),
                  children: [
                    const SizedBox(height: Gap.lg),
                    const Icon(
                      Icons.workspace_premium_rounded,
                      size: 52,
                      color: ArulColors.gold,
                    ),
                    const SizedBox(height: Gap.lg),
                    Text(
                      l10n.premiumHeadline,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineMedium?.copyWith(
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: Gap.md),
                    Text(
                      l10n.premiumSub,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: Colors.white.withValues(alpha: 0.72),
                      ),
                    ),
                    const SizedBox(height: Gap.xxl),
                    const PremiumBenefits(),
                  ],
                ),
              ),
              const PremiumFooter(),
            ],
          ),
        ),
      ),
    );
  }
}
