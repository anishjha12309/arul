import 'package:flutter/material.dart';

import '../../../app/l10n/app_localizations.dart';
import '../../../app/widgets/arul_sheet.dart';
import '../../../theme/arul_tokens.dart';
import 'member_view.dart';
import 'paywall_ornaments.dart';
import 'paywall_view.dart';

/// How a cancel-offer sheet closed. `accept` comes back only once the switch has been handed off.
enum CancelOfferChoice { accept, decline }

/// Picks the UPI route and starts the ₹99 switch; false when nothing started (the picker was closed).
typedef CancelOfferStart = Future<bool> Function();

/// The ₹99 save offer after "Cancel it"; Not now, back and the scrim all resolve `decline`.
Future<CancelOfferChoice?> showCancelOfferSheet(
  BuildContext context, {
  required String price,
  required String offerPrice,
  required String? accessUntil,
  required CancelOfferStart onAccept,
  required Future<void> Function() untilHandedOff,
}) => showArulSheet<CancelOfferChoice>(
  context,
  // The paywall's own ground, like every sheet /premium opens.
  surfaceColor: ArulTokens.paywallCream,
  enableDrag: false,
  builder: (_) => _CancelOfferBody(
    price: price,
    offerPrice: offerPrice,
    accessUntil: accessUntil,
    onAccept: onAccept,
    untilHandedOff: untilHandedOff,
  ),
);

/// After a switch that did not go through; null = back or scrim, which must change nothing.
Future<CancelOfferChoice?> showCancelOfferRetrySheet(
  BuildContext context, {
  required String reason,
  required CancelOfferStart onRetry,
  required Future<void> Function() untilHandedOff,
}) => showArulSheet<CancelOfferChoice>(
  context,
  surfaceColor: ArulTokens.paywallCream,
  enableDrag: false,
  builder: (_) => _CancelOfferRetryBody(
    reason: reason,
    onRetry: onRetry,
    untilHandedOff: untilHandedOff,
  ),
);

// Closes as `accept` only after the handoff: the screen's purchase listener owns everything after.
mixin _SwitchStarter<T extends StatefulWidget> on State<T> {
  // The picker is up or the initiate is running: no second start, and no leaving mid-initiate.
  bool _starting = false;

  bool _busy = false;

  Future<void> _start(
    CancelOfferStart start,
    Future<void> Function() untilHandedOff,
  ) async {
    if (_starting) return;
    setState(() => _starting = true);
    var handedOff = false;
    try {
      final started = await start();
      if (!started || !mounted) return;
      setState(() => _busy = true);
      await untilHandedOff();
      handedOff = true;
      _close(CancelOfferChoice.accept);
    } finally {
      // A closing sheet keeps its spinner through the exit rather than flash the idle label.
      if (mounted && !handedOff) {
        setState(() {
          _starting = false;
          _busy = false;
        });
      }
    }
  }

  void _close(CancelOfferChoice? choice) {
    if (!mounted) return;
    final route = ModalRoute.of<CancelOfferChoice>(context);
    final navigator = Navigator.of(context);
    if (route == null || route.isCurrent) {
      navigator.pop(choice);
    } else if (route.isActive) {
      // Something opened above the sheet meanwhile; a plain pop would close that instead.
      navigator.removeRoute(route, choice);
    }
  }
}

// The member view's ground under a sheet: the temple plate over cream, text clamped as there.
class _SheetGround extends StatelessWidget {
  const _SheetGround({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      const Positioned.fill(child: PaywallBackgroundPlate()),
      MediaQuery.withClampedTextScaling(
        maxScaleFactor: 1.3,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
            ArulTokens.premiumMemberPageInset,
            18,
            ArulTokens.premiumMemberPageInset,
            14,
          ),
          child: child,
        ),
      ),
    ],
  );
}

// The plan hero's crest: gold rule, floret, gopuram, floret, rule.
class _Crest extends StatelessWidget {
  const _Crest();

  @override
  Widget build(BuildContext context) => const Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      PaywallOrnamentWing(
        ruleWidth: ArulTokens.premiumMemberHeroRuleWidth,
        floretSize: ArulTokens.premiumMemberHeroFloretSize,
        gap: ArulTokens.premiumMemberHeroOrnamentGap,
      ),
      SizedBox(width: ArulTokens.premiumMemberHeroOrnamentGap),
      PaywallOrnamentImage(ornament: PaywallOrnament.gopuram, width: 46),
      SizedBox(width: ArulTokens.premiumMemberHeroOrnamentGap),
      PaywallOrnamentWing(
        ruleWidth: ArulTokens.premiumMemberHeroRuleWidth,
        floretSize: ArulTokens.premiumMemberHeroFloretSize,
        gap: ArulTokens.premiumMemberHeroOrnamentGap,
        mirrored: true,
      ),
    ],
  );
}

class _CancelOfferBody extends StatefulWidget {
  const _CancelOfferBody({
    required this.price,
    required this.offerPrice,
    required this.accessUntil,
    required this.onAccept,
    required this.untilHandedOff,
  });

  final String price;
  final String offerPrice;
  final String? accessUntil;
  final CancelOfferStart onAccept;
  final Future<void> Function() untilHandedOff;

  @override
  State<_CancelOfferBody> createState() => _CancelOfferBodyState();
}

class _CancelOfferBodyState extends State<_CancelOfferBody>
    with _SwitchStarter {
  void _decline() {
    if (_starting) return;
    _close(CancelOfferChoice.decline);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    // No-break spaces: the date split after its day number on a real phone.
    final accessUntil = widget.accessUntil?.replaceAll(' ', ' ');
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _decline();
      },
      child: _SheetGround(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _Crest(),
            const SizedBox(height: 12),
            // The member view's card around the paywall's monthly lockup.
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: ArulTokens.paywallPanelFill,
                border: Border.all(color: ArulTokens.paywallBorderSoft),
                borderRadius: BorderRadius.circular(
                  ArulTokens.premiumMemberCardRadius,
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: ArulTokens.paywallTrialBadgeVerticalPadding,
                      ),
                      decoration: BoxDecoration(
                        color: ArulTokens.paywallMaroon,
                        borderRadius: BorderRadius.circular(
                          ArulTokens.pillRadius,
                        ),
                      ),
                      child: PaywallDisplayLabel(
                        text: l10n.cancelOfferEyebrow,
                        style: ArulTokens.paywallBadge,
                        trackCompensation: 2.3,
                      ),
                    ),
                    const SizedBox(height: 10),
                    // Gelasio, like the lockup under it: the one bundled serif that carries a ₹.
                    Text(
                      widget.price,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontFamily: ArulTokens.paywallNumeralFamily,
                        fontSize: 22,
                        height: 1.2,
                        color: ArulTokens.paywallInkFaint,
                        decoration: TextDecoration.lineThrough,
                        decorationThickness: 1.5,
                        decorationColor: ArulTokens.paywallInkFaint,
                      ),
                    ),
                    const SizedBox(height: 2),
                    PriceLockup(price: widget.offerPrice),
                    const SizedBox(height: 10),
                    PaywallRuledLabel(
                      child: PaywallDisplayLabel(
                        text: l10n.premiumPerMonthCaption,
                        style: ArulTokens.paywallPriceCaption,
                        trackCompensation: 3.92,
                      ),
                    ),
                    const Padding(
                      padding: EdgeInsets.only(
                        top: ArulTokens.paywallPriceDividerTopGap,
                        bottom: ArulTokens.paywallPriceDividerBottomGap,
                      ),
                      child: PaywallOrnamentImage(
                        ornament: PaywallOrnament.priceDivider,
                        width: ArulTokens.paywallPriceOrnamentWidth,
                      ),
                    ),
                    Text(
                      l10n.cancelOfferForever,
                      textAlign: TextAlign.center,
                      style: ArulTokens.premiumMemberBillingValue,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      l10n.cancelOfferApprove(widget.offerPrice, widget.price),
                      textAlign: TextAlign.center,
                      style: ArulTokens.premiumMemberBody.copyWith(
                        fontSize: 13.5,
                        height: 1.45,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 18),
            ShrineCta(
              label: l10n.cancelOfferAccept,
              busy: _busy,
              bottomLotus: true,
              onPressed: _starting
                  ? null
                  : () => _start(widget.onAccept, widget.untilHandedOff),
            ),
            const SizedBox(height: ArulTokens.premiumCelebrateLotusClearance),
            TextButton(
              onPressed: _starting ? null : _decline,
              style: TextButton.styleFrom(
                foregroundColor: ArulTokens.paywallMaroon,
                textStyle: ArulTokens.premiumMemberCancelLabel,
                minimumSize: const Size.fromHeight(ArulTokens.minHitTarget),
              ),
              child: Text(l10n.referNotNow, textAlign: TextAlign.center),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: ArulTokens.premiumMemberFootnoteInset,
              ),
              child: Text(
                accessUntil == null
                    ? l10n.cancelOfferDeclineNote
                    : l10n.cancelOfferDeclineNoteDate(accessUntil),
                textAlign: TextAlign.center,
                style: ArulTokens.premiumMemberFootnote,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CancelOfferRetryBody extends StatefulWidget {
  const _CancelOfferRetryBody({
    required this.reason,
    required this.onRetry,
    required this.untilHandedOff,
  });

  final String reason;
  final CancelOfferStart onRetry;
  final Future<void> Function() untilHandedOff;

  @override
  State<_CancelOfferRetryBody> createState() => _CancelOfferRetryBodyState();
}

class _CancelOfferRetryBodyState extends State<_CancelOfferRetryBody>
    with _SwitchStarter {
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return PopScope(
      canPop: !_starting,
      child: _SheetGround(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _Crest(),
            const SizedBox(height: ArulTokens.premiumMemberHeadlineGap),
            Text(
              l10n.cancelOfferRetryTitle,
              textAlign: TextAlign.center,
              style: ArulTokens.premiumMemberHeadline.copyWith(fontSize: 20),
            ),
            const SizedBox(height: ArulTokens.premiumMemberSublineGap),
            Text(
              widget.reason,
              textAlign: TextAlign.center,
              style: ArulTokens.premiumMemberBody,
            ),
            const SizedBox(height: 20),
            ShrineCta(
              label: l10n.cancelOfferTryAgain,
              busy: _busy,
              onPressed: _starting
                  ? null
                  : () => _start(widget.onRetry, widget.untilHandedOff),
            ),
            const SizedBox(height: 14),
            PremiumPlanCancelButton(
              busy: false,
              tapKey: 'cancel-offer-retry-cancel',
              onTap: _starting ? null : () => _close(CancelOfferChoice.decline),
            ),
          ],
        ),
      ),
    );
  }
}
