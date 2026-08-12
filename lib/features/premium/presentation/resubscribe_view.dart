import 'package:flutter/material.dart';

import '../../../core/haptics/arul_haptics.dart';
import '../../../core/upi/upi_apps.dart';
import '../../../theme/arul_tokens.dart';
import 'member_view.dart';
import 'paywall_ornaments.dart';
import 'paywall_view.dart';

/// The cancelled-but-paid-through premium state and its resubscribe action.
class ArulResubscribeView extends StatelessWidget {
  const ArulResubscribeView({
    super.key,
    required this.monthlyPrice,
    required this.accessUntil,
    required this.selectedUpiApp,
    required this.canChangeUpiApp,
    required this.purchaseBusy,
    required this.onBack,
    required this.onChangeUpiApp,
    required this.onResubscribe,
  });

  final String monthlyPrice;
  final String? accessUntil;
  final UpiApp? selectedUpiApp;
  final bool canChangeUpiApp;
  final bool purchaseBusy;
  final VoidCallback onBack;
  final VoidCallback onChangeUpiApp;
  final VoidCallback onResubscribe;

  @override
  Widget build(BuildContext context) {
    return PaywallGround(
      child: Column(
        children: [
          PremiumPlanNav(onBack: onBack),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(
                ArulTokens.premiumMemberPageInset,
                0,
                ArulTokens.premiumMemberPageInset,
                ArulTokens.premiumMemberScrollBottom,
              ),
              children: [
                const PremiumPlanHero(
                  headline: 'Auto-renew is off',
                  subline:
                      'You keep full access until your paid period ends. You '
                      "won't be charged again.",
                  status: 'Auto-renew off',
                  statusTone: PremiumPlanStatusTone.warning,
                  ornamentStatus: true,
                ),
                const SizedBox(height: ArulTokens.premiumMemberSectionGap),
                PremiumPlanBillingCard(
                  rows: [
                    const PremiumPlanBillingRowData(
                      label: 'Plan',
                      value: 'Monthly',
                    ),
                    const PremiumPlanBillingRowData(
                      label: 'Payment',
                      value: 'UPI Autopay',
                    ),
                    if (accessUntil != null)
                      PremiumPlanBillingRowData(
                        label: 'Access until',
                        value: accessUntil!,
                      ),
                  ],
                ),
                if (selectedUpiApp != null) ...[
                  const SizedBox(
                    height: ArulTokens.premiumResubscribePayUsingTop,
                  ),
                  const Text(
                    'Pay using',
                    style: ArulTokens.premiumResubscribePayUsing,
                  ),
                  const SizedBox(
                    height: ArulTokens.premiumResubscribePayUsingGap,
                  ),
                  _PremiumUpiSelector(
                    app: selectedUpiApp!,
                    canChange: canChangeUpiApp,
                    enabled: !purchaseBusy,
                    onChange: onChangeUpiApp,
                  ),
                ],
                const SizedBox(height: ArulTokens.premiumResubscribeCtaTop),
                ShrineCta(
                  label: 'Resubscribe',
                  busy: purchaseBusy,
                  bottomLotus: true,
                  onPressed: purchaseBusy ? null : onResubscribe,
                ),
                const SizedBox(
                  height: ArulTokens.premiumResubscribeCtaLotusClearance,
                ),
                const SizedBox(
                  height: ArulTokens.premiumResubscribeFootnoteTop,
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: ArulTokens.premiumResubscribeFootnoteInset,
                  ),
                  child: Text(
                    'Resubscribing sets up a fresh UPI Autopay mandate at '
                    '$monthlyPrice a month.',
                    textAlign: TextAlign.center,
                    style: ArulTokens.premiumResubscribeFootnote,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PremiumUpiSelector extends StatelessWidget {
  const _PremiumUpiSelector({
    required this.app,
    required this.canChange,
    required this.enabled,
    required this.onChange,
  });

  final UpiApp app;
  final bool canChange;
  final bool enabled;
  final VoidCallback onChange;

  @override
  Widget build(BuildContext context) {
    final interactive = canChange && enabled;
    return Semantics(
      button: canChange,
      enabled: interactive,
      child: GestureDetector(
        key: const ValueKey('resubscribe-upi-selector'),
        behavior: HitTestBehavior.opaque,
        onTapDown: interactive ? (_) => ArulHaptics.tap() : null,
        onTap: interactive ? onChange : null,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: ArulTokens.premiumResubscribeUpiHorizontal,
            vertical: ArulTokens.premiumResubscribeUpiVertical,
          ),
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: ArulTokens.paywallBorderControl),
            borderRadius: BorderRadius.circular(
              ArulTokens.premiumResubscribeUpiRadius,
            ),
          ),
          child: Row(
            children: [
              _PremiumUpiIcon(app: app),
              const SizedBox(width: ArulTokens.premiumResubscribeUpiIconGap),
              Expanded(
                child: Text(
                  app.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ArulTokens.premiumResubscribeUpiName,
                ),
              ),
              if (canChange) ...[
                Opacity(
                  opacity: enabled ? 1 : ArulTokens.premiumMemberDisabledAlpha,
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Change',
                        style: ArulTokens.premiumResubscribeChange,
                      ),
                      SizedBox(width: ArulTokens.premiumResubscribeChangeGap),
                      Icon(
                        Icons.expand_more,
                        size: ArulTokens.premiumResubscribeChevronSize,
                        color: ArulTokens.paywallMaroon,
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _PremiumUpiIcon extends StatelessWidget {
  const _PremiumUpiIcon({required this.app});

  final UpiApp app;

  @override
  Widget build(BuildContext context) {
    final icon = app.icon;
    if (icon == null) {
      return const SizedBox.square(
        dimension: ArulTokens.premiumResubscribeUpiIconSize,
        child: Icon(
          Icons.account_balance_wallet_outlined,
          color: ArulTokens.paywallMaroon,
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(
        ArulTokens.premiumResubscribeUpiIconRadius,
      ),
      child: Image.memory(
        icon,
        width: ArulTokens.premiumResubscribeUpiIconSize,
        height: ArulTokens.premiumResubscribeUpiIconSize,
        gaplessPlayback: true,
      ),
    );
  }
}
