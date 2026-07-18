import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/widgets/arul_toast.dart';
import '../../../app/widgets/cta_button.dart';
import '../../../app/widgets/gopuram_mark.dart';
import '../../../core/config/app_config.dart';
import '../../../theme/arul_tokens.dart';
import '../providers/premium_purchase_provider.dart';

/// Paywall. Reached only from a blocked gated action; `source` says which — the
/// one number that tells you which verb actually sells the product.
///
/// Design-only pass (design_handoff_arul spec, "Premium screen (3a)"): close
/// X top-left, centered gopuram + wordmark + subline, a perk card, a
/// gold-bordered plan card and the green CTA. Copy is hardcoded verbatim for
/// this pass — deliberately not yet routed through l10n.
class PremiumScreen extends ConsumerWidget {
  const PremiumScreen({super.key, required this.source});

  final String source;

  static const _perks = [
    (icon: Icons.wallpaper, text: 'All 428 wallpapers, still and live'),
    (icon: Icons.movie, text: 'Live wallpapers play on your home screen'),
    (icon: Icons.ios_share, text: 'Apply and share without limits'),
    (icon: Icons.auto_awesome, text: 'New arrivals every week'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // PhonePe purchase flow (ported): initiate → SDK → status poll → refresh
    // entitlement. Success/failure feedback is reactive so the flow survives
    // rebuilds while the SDK UI is up.
    ref.listen<PurchaseState>(premiumPurchaseProvider, (prev, next) {
      switch (next) {
        case PurchaseSuccess():
          showArulToast(context, 'Welcome to Arul Premium!');
          if (context.canPop()) context.pop();
        case PurchaseError(:final message):
          showArulToast(context, message, kind: ToastKind.error);
          ref.read(premiumPurchaseProvider.notifier).reset();
        case _:
          break;
      }
    });
    final purchase = ref.watch(premiumPurchaseProvider);
    final purchaseBusy =
        purchase is PurchaseLoading || purchase is PurchaseProcessing;

    final isDark = Theme.of(context).brightness == Brightness.dark;

    final bg = isDark ? ArulTokens.darkSurface : ArulTokens.ivory;
    final textPrimary = isDark ? ArulTokens.darkText : ArulTokens.lightText;
    final textSecondary = isDark
        ? ArulTokens.darkBodyWarm
        : ArulTokens.lightSecondary;
    final accent = isDark ? ArulTokens.gold : ArulTokens.maroon;
    final cardBg = isDark ? ArulTokens.cardBgDark04 : ArulTokens.cardBgLight;
    final cardBorder = isDark
        ? ArulTokens.cardBorderDark09
        : ArulTokens.cardBorderLight;
    final planGradient = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: isDark
          ? [
              const Color.fromRGBO(122, 30, 51, 0.4),
              const Color.fromRGBO(212, 160, 23, 0.08),
            ]
          : [
              const Color.fromRGBO(122, 30, 51, 0.08),
              const Color.fromRGBO(212, 160, 23, 0.10),
            ],
    );
    final planSecondary = isDark
        ? ArulTokens.darkTextSecondary
        : ArulTokens.lightSecondary;
    final footnote = isDark ? ArulTokens.darkFaint : ArulTokens.lightFaint;

    return Scaffold(
      backgroundColor: bg,
      body: SafeArea(
        child: Column(
          children: [
            Align(
              alignment: Alignment.topLeft,
              child: Padding(
                padding: const EdgeInsets.only(
                  left: ArulTokens.screenPadding - 4,
                  top: 6,
                ),
                child: IconButton(
                  onPressed: () => context.pop(),
                  icon: Icon(Icons.close, color: textPrimary),
                  tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                ),
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  ArulTokens.screenPadding,
                  8,
                  ArulTokens.screenPadding,
                  24,
                ),
                children: [
                  Column(
                    children: [
                      const SizedBox(height: 18),
                      GopuramMark(size: 40, color: accent),
                      const SizedBox(height: 8),
                      Text(
                        'Arul Premium',
                        style: ArulTokens.screenTitle.copyWith(
                          fontSize: 30,
                          color: textPrimary,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'The full collection, alive on your screen',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 14,
                          height: 1.5,
                          color: textSecondary,
                        ),
                      ),
                      const SizedBox(height: 4),
                    ],
                  ),
                  const SizedBox(height: ArulTokens.contentGap),
                  // Perks card.
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: ArulTokens.cardPadding20,
                    ),
                    decoration: BoxDecoration(
                      color: cardBg,
                      border: Border.all(color: cardBorder),
                      borderRadius: BorderRadius.circular(
                        ArulTokens.cardRadius,
                      ),
                    ),
                    child: Column(
                      children: [
                        for (var i = 0; i < _perks.length; i++) ...[
                          if (i > 0) const SizedBox(height: 14),
                          Row(
                            children: [
                              Icon(_perks[i].icon, size: 22, color: accent),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Text(
                                  _perks[i].text,
                                  style: TextStyle(
                                    fontSize: 14.5,
                                    color: textPrimary,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: ArulTokens.contentGap),
                  // Plan card.
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 16,
                    ),
                    decoration: BoxDecoration(
                      gradient: planGradient,
                      border: Border.all(
                        color: ArulTokens.goldBorderSolid,
                        width: 1.5,
                      ),
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              RichText(
                                text: TextSpan(
                                  children: [
                                    TextSpan(
                                      text: '₹199 ',
                                      style: ArulTokens.priceNumeral.copyWith(
                                        fontSize: 20,
                                        color: textPrimary,
                                      ),
                                    ),
                                    TextSpan(
                                      text: '/ month',
                                      style: TextStyle(
                                        fontSize: 13,
                                        color: planSecondary,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'UPI Autopay · cancel anytime',
                                style: TextStyle(
                                  fontSize: 12.5,
                                  color: planSecondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 13,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: ArulTokens.gold,
                            borderRadius: BorderRadius.circular(
                              ArulTokens.pillRadius,
                            ),
                          ),
                          // 1 day, not 7: the server grants exactly TRIAL_DAYS=1
                          // (payments.ts) and debits ₹199 at trial end. Promising
                          // more than the mandate honours is how you get chargebacks.
                          child: const Text(
                            '1 DAY FREE',
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.46, // .04em @ 11.5px
                              color: ArulTokens.darkSurface,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: ArulTokens.contentGap),
                  CtaButton(
                    label: 'Start free trial',
                    busy: purchaseBusy,
                    height: ArulTokens.ctaHeight54,
                    fontSize: 16,
                    onPressed: purchaseBusy
                        ? null
                        : () {
                            if (!AppConfig.hasBackend) {
                              // Pre-Phase-0 stub: no Worker to initiate against.
                              showArulToast(context, 'Premium is coming soon.');
                              return;
                            }
                            ref
                                .read(premiumPurchaseProvider.notifier)
                                .startTrial();
                          },
                  ),
                  const SizedBox(height: ArulTokens.contentGap),
                  // The ₹2 is named here on purpose. Setting up a UPI mandate
                  // costs a ₹2 PENNY_DROP that PhonePe reverses immediately — but
                  // the user still SEES ₹2 leave their account, and an unexplained
                  // debit on a screen that said "free" reads as a scam.
                  Text(
                    'Free for 1 day, then ₹199/month. UPI Autopay verifies your '
                    'account with ₹2, refunded instantly. Browsing stays free '
                    'forever.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.6,
                      color: footnote,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
