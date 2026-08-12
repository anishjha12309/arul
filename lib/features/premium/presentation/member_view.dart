import 'package:flutter/material.dart';

import '../../../core/haptics/arul_haptics.dart';
import '../../../theme/arul_tokens.dart';
import 'paywall_ornaments.dart';

/// The premium plan home for trialing and active subscribers.
///
/// Subscription state and actions remain owned by PremiumScreen; this widget
/// only renders the five values that distinguish the two member states.
class ArulMemberView extends StatelessWidget {
  const ArulMemberView({
    super.key,
    required this.trialing,
    required this.renewalDate,
    required this.cancelBusy,
    required this.onBack,
    required this.onCancel,
  });

  final bool trialing;
  final String? renewalDate;
  final bool cancelBusy;
  final VoidCallback onBack;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final headline = trialing ? "You're on the free trial" : "You're a member";
    final subline = trialing
        ? 'Full access to every wallpaper. Your first ₹199 payment is charged '
              'when the trial ends.'
        : 'Every wallpaper, still and live, is yours to apply and share.';
    final dateLabel = trialing ? 'Trial ends' : 'Renews on';
    final footnote = trialing
        ? 'Cancel before the trial ends and you are never charged. Billed '
              'monthly via UPI Autopay.'
        : 'Billed monthly via UPI Autopay. Cancel anytime — your access '
              'continues until the current period ends.';

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
                  status: trialing ? 'Free trial' : 'Active',
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

/// Ringed back control and serif title shared by premium plan pages.
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

/// Temple hero shared by active, trialing and cancelled premium states.
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

/// Positive or warning status treatment for premium plan heroes.
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

/// One immutable row in a premium plan billing card.
class PremiumPlanBillingRowData {
  const PremiumPlanBillingRowData({required this.label, required this.value});

  final String label;
  final String value;
}

/// Floret-led billing details shared by premium plan pages.
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
    return const Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        PaywallOrnamentImage(
          ornament: PaywallOrnament.lotus,
          width: ArulTokens.premiumMemberReminderLotusSize,
        ),
        SizedBox(width: ArulTokens.premiumMemberReminderGap),
        Flexible(
          child: Text(
            "We'll remind you 24 hours before every renewal.",
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
                  ArulHaptics.tap();
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
                    child: SizedBox.square(
                      key: ValueKey('member-cancel-progress'),
                      dimension: ArulTokens.premiumMemberProgressSize,
                      child: CircularProgressIndicator(
                        strokeWidth: ArulTokens.premiumMemberProgressStroke,
                        color: ArulTokens.paywallMaroon,
                      ),
                    ),
                  )
                : const Stack(
                    alignment: Alignment.center,
                    children: [
                      Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal:
                              ArulTokens.premiumMemberCancelFloretInset * 3,
                        ),
                        child: Text(
                          'Cancel subscription',
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
