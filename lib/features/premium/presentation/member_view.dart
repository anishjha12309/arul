import 'package:flutter/material.dart';

import '../../../app/l10n/app_localizations.dart';
import '../../../app/widgets/arul_spinner.dart';
import '../../../core/haptics/arul_haptics.dart';
import '../../../theme/arul_tokens.dart';
import 'paywall_ornaments.dart';

/// The premium plan home for trialing and active subscribers.
///
/// State and actions stay owned by PremiumScreen -> this renders only the five distinguishing values.
class ArulMemberView extends StatelessWidget {
  const ArulMemberView({
    super.key,
    required this.trialing,
    required this.renewalDate,
    required this.monthlyPrice,
    required this.cancelBusy,
    required this.onBack,
    required this.onCancel,
  });

  final bool trialing;
  final String? renewalDate;
  final String monthlyPrice;
  final bool cancelBusy;
  final VoidCallback onBack;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final headline = trialing
        ? l10n.settingsPremiumSubTrial
        : l10n.premiumMemberHeadline;
    final subline = trialing
        ? l10n.premiumMemberTrialSubline(monthlyPrice)
        : l10n.premiumMemberSubline;
    final dateLabel = trialing
        ? l10n.premiumTrialEndsLabel
        : l10n.premiumRenewsOnLabel;
    final footnote = trialing
        ? l10n.premiumMemberTrialFootnote
        : l10n.premiumMemberFootnote;

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
                PremiumPlanHero(
                  headline: headline,
                  subline: subline,
                  status: trialing
                      ? l10n.premiumStatusTrial
                      : l10n.premiumStatusActive,
                ),
                const SizedBox(height: ArulTokens.premiumMemberSectionGap),
                PremiumPlanBillingCard(
                  rows: [
                    PremiumPlanBillingRowData(
                      label: l10n.premiumPlanLabel,
                      value: l10n.premiumPlanMonthly,
                    ),
                    PremiumPlanBillingRowData(
                      label: l10n.premiumPaymentLabel,
                      value: l10n.premiumPaymentUpiAutopay,
                    ),
                    if (renewalDate != null)
                      PremiumPlanBillingRowData(
                        label: dateLabel,
                        value: renewalDate!,
                      ),
                  ],
                ),
                const SizedBox(height: ArulTokens.premiumMemberReminderTop),
                const _RenewalReminder(),
                const SizedBox(height: ArulTokens.premiumMemberCancelTop),
                _MemberCancelButton(busy: cancelBusy, onTap: onCancel),
                const SizedBox(height: ArulTokens.premiumMemberFootnoteTop),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: ArulTokens.premiumMemberFootnoteInset,
                  ),
                  child: Text(
                    footnote,
                    textAlign: TextAlign.center,
                    style: ArulTokens.premiumMemberFootnote,
                  ),
                ),
                const SizedBox(height: ArulTokens.premiumMemberFooterTop),
                const PaywallTempleDivider(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class PremiumPlanNav extends StatelessWidget {
  const PremiumPlanNav({super.key, required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        ArulTokens.premiumMemberPageInset,
        ArulTokens.premiumMemberNavTop,
        ArulTokens.premiumMemberPageInset,
        ArulTokens.premiumMemberNavBottom,
      ),
      child: Row(
        children: [
          Semantics(
            button: true,
            label: MaterialLocalizations.of(context).backButtonTooltip,
            onTap: onBack,
            excludeSemantics: true,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (_) => ArulHaptics.tap(),
              onTap: onBack,
              child: SizedBox.square(
                dimension: ArulTokens.minHitTarget,
                child: Center(
                  child: Container(
                    width: ArulTokens.premiumMemberBackRingSize,
                    height: ArulTokens.premiumMemberBackRingSize,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: ArulTokens.paywallGold700,
                        width: ArulTokens.premiumMemberControlStroke,
                      ),
                    ),
                    child: const Icon(
                      Icons.arrow_back,
                      size: ArulTokens.premiumMemberBackIconSize,
                      color: ArulTokens.paywallMaroon,
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: ArulTokens.premiumMemberNavGap),
          const Expanded(
            child: Text(
              'Arul Premium',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ArulTokens.premiumMemberNavTitle,
            ),
          ),
        ],
      ),
    );
  }
}

class PremiumPlanHero extends StatelessWidget {
  const PremiumPlanHero({
    super.key,
    required this.headline,
    required this.subline,
    required this.status,
    this.statusTone = PremiumPlanStatusTone.positive,
    this.ornamentStatus = false,
  });

  final String headline;
  final String subline;
  final String status;
  final PremiumPlanStatusTone statusTone;
  final bool ornamentStatus;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: ArulTokens.premiumMemberHeroHorizontal,
        vertical: ArulTokens.premiumMemberHeroVertical,
      ),
      decoration: BoxDecoration(
        gradient: ArulTokens.paywallPanelFill,
        border: Border.all(color: ArulTokens.paywallBorderSoft),
        borderRadius: BorderRadius.circular(ArulTokens.premiumMemberCardRadius),
      ),
      child: Column(
        children: [
          const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              PaywallOrnamentWing(
                ruleWidth: ArulTokens.premiumMemberHeroRuleWidth,
                floretSize: ArulTokens.premiumMemberHeroFloretSize,
                gap: ArulTokens.premiumMemberHeroOrnamentGap,
              ),
              SizedBox(width: ArulTokens.premiumMemberHeroOrnamentGap),
              PaywallOrnamentImage(
                ornament: PaywallOrnament.gopuram,
                width: ArulTokens.premiumMemberHeroGopuramSize,
              ),
              SizedBox(width: ArulTokens.premiumMemberHeroOrnamentGap),
              PaywallOrnamentWing(
                ruleWidth: ArulTokens.premiumMemberHeroRuleWidth,
                floretSize: ArulTokens.premiumMemberHeroFloretSize,
                gap: ArulTokens.premiumMemberHeroOrnamentGap,
                mirrored: true,
              ),
            ],
          ),
          const SizedBox(height: ArulTokens.premiumMemberHeadlineGap),
          Text(
            headline,
            textAlign: TextAlign.center,
            style: ArulTokens.premiumMemberHeadline,
          ),
          const SizedBox(height: ArulTokens.premiumMemberSublineGap),
          Text(
            subline,
            textAlign: TextAlign.center,
            style: ArulTokens.premiumMemberBody,
          ),
          const SizedBox(height: ArulTokens.premiumMemberStatusGap),
          PremiumPlanStatusChip(
            label: status,
            tone: statusTone,
            ornamented: ornamentStatus,
          ),
        ],
      ),
    );
  }
}

enum PremiumPlanStatusTone { positive, warning }

class PremiumPlanStatusChip extends StatelessWidget {
  const PremiumPlanStatusChip({
    super.key,
    required this.label,
    required this.tone,
    this.ornamented = false,
  });

  final String label;
  final PremiumPlanStatusTone tone;
  final bool ornamented;

  @override
  Widget build(BuildContext context) {
    final foreground = tone == PremiumPlanStatusTone.positive
        ? ArulTokens.ctaGreen
        : ArulTokens.paywallGoldDeep;
    final fillAlpha = tone == PremiumPlanStatusTone.positive
        ? ArulTokens.premiumMemberStatusFillAlpha
        : ArulTokens.premiumResubscribeStatusFillAlpha;
    final chip = Container(
      padding: const EdgeInsets.symmetric(
        horizontal: ArulTokens.premiumMemberStatusHorizontal,
        vertical: ArulTokens.premiumMemberStatusVertical,
      ),
      decoration: BoxDecoration(
        color: foreground.withValues(alpha: fillAlpha),
        borderRadius: BorderRadius.circular(ArulTokens.pillRadius),
        border: Border.all(
          color: foreground.withValues(
            alpha: ArulTokens.premiumMemberStatusBorderAlpha,
          ),
        ),
      ),
      child: Text(
        label.toUpperCase(),
        style: tone == PremiumPlanStatusTone.positive
            ? ArulTokens.premiumMemberStatus
            : ArulTokens.premiumResubscribeStatus,
      ),
    );
    if (!ornamented) return chip;
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const PaywallOrnamentImage(
            ornament: PaywallOrnament.floretGold,
            width: ArulTokens.premiumResubscribeStatusFloretSize,
          ),
          const SizedBox(width: ArulTokens.premiumResubscribeStatusFloretGap),
          chip,
          const SizedBox(width: ArulTokens.premiumResubscribeStatusFloretGap),
          const PaywallOrnamentImage(
            ornament: PaywallOrnament.floretGold,
            width: ArulTokens.premiumResubscribeStatusFloretSize,
          ),
        ],
      ),
    );
  }
}

class PremiumPlanBillingRowData {
  const PremiumPlanBillingRowData({required this.label, required this.value});

  final String label;
  final String value;
}

class PremiumPlanBillingCard extends StatelessWidget {
  const PremiumPlanBillingCard({super.key, required this.rows});

  final List<PremiumPlanBillingRowData> rows;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: ArulTokens.paywallPanelFill,
        border: Border.all(color: ArulTokens.paywallBorderSoft),
        borderRadius: BorderRadius.circular(ArulTokens.premiumMemberCardRadius),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (var index = 0; index < rows.length; index++) ...[
            if (index > 0) const _PremiumPlanBillingDivider(),
            PremiumPlanBillingRow(
              label: rows[index].label,
              value: rows[index].value,
            ),
          ],
        ],
      ),
    );
  }
}

class PremiumPlanBillingRow extends StatelessWidget {
  const PremiumPlanBillingRow({
    super.key,
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: ArulTokens.premiumMemberRowHorizontal,
        vertical: ArulTokens.premiumMemberRowVertical,
      ),
      child: Row(
        children: [
          const PaywallOrnamentImage(
            ornament: PaywallOrnament.floretGold,
            width: ArulTokens.premiumMemberRowFloretSize,
          ),
          const SizedBox(width: ArulTokens.premiumMemberRowLabelGap),
          Expanded(
            child: Text(label, style: ArulTokens.premiumMemberBillingLabel),
          ),
          const SizedBox(width: ArulTokens.premiumMemberRowLabelGap),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: ArulTokens.premiumMemberBillingValue,
            ),
          ),
        ],
      ),
    );
  }
}

class _PremiumPlanBillingDivider extends StatelessWidget {
  const _PremiumPlanBillingDivider();

  @override
  Widget build(BuildContext context) => const SizedBox(
    height: ArulTokens.paywallOrnamentRuleThickness,
    child: ColoredBox(color: ArulTokens.paywallBorderSoft),
  );
}

class _RenewalReminder extends StatelessWidget {
  const _RenewalReminder();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const PaywallOrnamentImage(
          ornament: PaywallOrnament.lotus,
          width: ArulTokens.premiumMemberReminderLotusSize,
        ),
        const SizedBox(width: ArulTokens.premiumMemberReminderGap),
        Flexible(
          child: Text(
            AppLocalizations.of(context).premiumRenewalReminder,
            textAlign: TextAlign.center,
            style: ArulTokens.premiumMemberReminder,
          ),
        ),
        SizedBox(width: ArulTokens.premiumMemberReminderGap),
        PaywallOrnamentImage(
          ornament: PaywallOrnament.lotus,
          width: ArulTokens.premiumMemberReminderLotusSize,
        ),
      ],
    );
  }
}

class _MemberCancelButton extends StatefulWidget {
  const _MemberCancelButton({required this.busy, required this.onTap});

  final bool busy;
  final VoidCallback onTap;

  @override
  State<_MemberCancelButton> createState() => _MemberCancelButtonState();
}

class _MemberCancelButtonState extends State<_MemberCancelButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final disabled = widget.busy;
    final fillAlpha = _pressed
        ? ArulTokens.premiumMemberCancelPressedAlpha
        : ArulTokens.premiumMemberCancelFillAlpha;

    return Semantics(
      button: true,
      enabled: !disabled,
      child: Opacity(
        opacity: disabled ? ArulTokens.premiumMemberDisabledAlpha : 1,
        child: GestureDetector(
          key: const ValueKey('member-cancel-button'),
          behavior: HitTestBehavior.opaque,
          onTapDown: disabled
              ? null
              : (_) {
                  // Ending a paid subscription is the destructive commit — the same beat as
                  // account delete, so the hand learns one weight for "this takes something away".
                  ArulHaptics.heavy();
                  setState(() => _pressed = true);
                },
          onTapUp: disabled ? null : (_) => setState(() => _pressed = false),
          onTapCancel: disabled ? null : () => setState(() => _pressed = false),
          onTap: disabled ? null : widget.onTap,
          child: Container(
            height: ArulTokens.premiumMemberCancelHeight,
            decoration: BoxDecoration(
              color: ArulTokens.paywallMaroon.withValues(alpha: fillAlpha),
              border: Border.all(
                color: ArulTokens.paywallMaroon.withValues(
                  alpha: ArulTokens.premiumMemberCancelBorderAlpha,
                ),
                width: ArulTokens.premiumMemberControlStroke,
              ),
              borderRadius: BorderRadius.circular(ArulTokens.pillRadius),
            ),
            child: widget.busy
                ? const Center(
                    child: ArulSpinner(
                      key: ValueKey('member-cancel-progress'),
                      size: ArulTokens.premiumMemberProgressSize,
                      strokeWidth: ArulTokens.premiumMemberProgressStroke,
                      color: ArulTokens.paywallMaroon,
                    ),
                  )
                : Stack(
                    alignment: Alignment.center,
                    children: [
                      Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal:
                              ArulTokens.premiumMemberCancelFloretInset * 3,
                        ),
                        child: Text(
                          AppLocalizations.of(context).premiumCancelSubscription,
                          textAlign: TextAlign.center,
                          style: ArulTokens.premiumMemberCancelLabel,
                        ),
                      ),
                      Positioned(
                        left: ArulTokens.premiumMemberCancelFloretInset,
                        child: PaywallOrnamentImage(
                          ornament: PaywallOrnament.floret,
                          width: ArulTokens.premiumMemberCancelFloretSize,
                        ),
                      ),
                      Positioned(
                        right: ArulTokens.premiumMemberCancelFloretInset,
                        child: PaywallOrnamentImage(
                          ornament: PaywallOrnament.floret,
                          width: ArulTokens.premiumMemberCancelFloretSize,
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}
