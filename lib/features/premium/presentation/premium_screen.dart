import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/widgets/arul_toast.dart';
import '../../../app/widgets/cta_button.dart';
import '../../../app/widgets/gopuram_mark.dart';
import '../../../core/config/app_config.dart';
import '../../../data/models/subscription_model.dart';
import '../../../data/repositories/repository_providers.dart';
import '../../../theme/arul_tokens.dart';
import '../../referral/presentation/share_moment_sheet.dart';
import '../providers/entitlement_provider.dart';
import '../providers/premium_purchase_provider.dart';

/// Monthly price from app_config `prices` (paise) → "₹199". Falls back to the
/// launch price when the remote config hasn't loaded yet.
String _monthlyPrice(Map<String, dynamic>? prices) {
  final monthly = prices?['monthly'];
  if (monthly is Map && monthly['amount'] is num) {
    final rupees = (monthly['amount'] as num) / 100;
    final asInt = rupees.truncateToDouble() == rupees;
    return '₹${asInt ? rupees.toInt() : rupees.toStringAsFixed(2)}';
  }
  return '₹199';
}

/// Paywall. Reached only from a blocked gated action; `source` says which — the
/// one number that tells you which verb actually sells the product.
///
/// Design-only pass: close X top-left, centered gopuram + wordmark + subline,
/// a perk card, a
/// gold-bordered plan card and the green CTA. Copy is hardcoded verbatim for
/// this pass — deliberately not yet routed through l10n.
class PremiumScreen extends ConsumerStatefulWidget {
  const PremiumScreen({super.key, required this.source});

  final String source;

  static const _perks = [
    (icon: Icons.wallpaper, text: 'All 428 wallpapers, still and live'),
    (icon: Icons.movie, text: 'Live wallpapers play on your home screen'),
    (icon: Icons.ios_share, text: 'Apply and share without limits'),
    (icon: Icons.auto_awesome, text: 'New arrivals every week'),
  ];

  @override
  ConsumerState<PremiumScreen> createState() => _PremiumScreenState();
}

class _PremiumScreenState extends ConsumerState<PremiumScreen> {
  @override
  void initState() {
    super.initState();
    _reconcileIfPending();
  }

  /// Self-heal a subscription stranded at `pending`.
  ///
  /// The one state a user cannot recover from on their own is a row stuck at
  /// `pending` because the mandate setup completed at PhonePe but the S2S
  /// webhook never reached us. Re-reading `/me/subscription` can never fix
  /// that (it serves the same stale row); only POST /payments/status asks
  /// PhonePe directly and lets the Worker flip the row. So we do it FOR them,
  /// silently, on paywall open. Scoped to `pending` on purpose — every other
  /// user already has the right answer locally, so this costs a live PhonePe
  /// call for nobody else. Best-effort throughout: a reconcile failure must
  /// never surface here, because the user came to this screen to buy, not to
  /// be told about our webhook plumbing.
  Future<void> _reconcileIfPending() async {
    try {
      final entitlement = await ref.read(entitlementDetailProvider.future);
      if (!mounted) return;
      if (entitlement.subscription?.status != SubscriptionStatus.pending) {
        return;
      }
      // refreshStatus() invalidates entitlement itself, so a row that really
      // did complete flips this screen to premium with no further work.
      await ref.read(premiumPurchaseProvider.notifier).refreshStatus();
    } catch (_) {
      // Offline / server fault — leave the paywall exactly as it was.
    }
  }

  /// Offers the share, then closes the paywall.
  ///
  /// Order matters: the sheet is shown while this route is still mounted and the
  /// pop waits for it, so the sheet can never be left floating over a screen
  /// that has gone. It is entirely skippable — "Not now" is one tap and lands in
  /// the same place as closing the paywall would have.
  Future<void> _celebrate(BuildContext context) async {
    await ShareMomentSheet.show(
      context,
      title: "You're in",
      body:
          'Arul Premium is active. Know someone who would love these '
          'wallpapers? Send them one.',
      source: 'purchase_success',
    );
    if (!mounted) return;
    if (context.mounted && context.canPop()) context.pop();
  }

  @override
  Widget build(BuildContext context) {
    // PhonePe purchase flow (ported): initiate → SDK → status poll → refresh
    // entitlement. Success/failure feedback is reactive so the flow survives
    // rebuilds while the SDK UI is up.
    ref.listen<PurchaseState>(premiumPurchaseProvider, (prev, next) {
      switch (next) {
        case PurchaseSuccess():
          showArulToast(context, 'Welcome to Arul Premium!');
          // The single warmest moment in the app to ask for a share — and the
          // one point where the user has just decided Arul is worth paying for.
          // Awaited before the pop so the sheet is never orphaned by this route
          // disappearing beneath it.
          unawaited(_celebrate(context));
        case PurchaseError(:final message, :final cancelled):
          // A self-cancelled payment reads as neutral info, not a red failure
          // — the user changed their mind; nothing broke.
          showArulToast(
            context,
            message,
            kind: cancelled ? ToastKind.info : ToastKind.error,
          );
          ref.read(premiumPurchaseProvider.notifier).reset();
        case _:
          break;
      }
    });
    final purchase = ref.watch(premiumPurchaseProvider);
    final purchaseBusy =
        purchase is PurchaseLoading || purchase is PurchaseProcessing;

    // One free trial per user: a non-null trial_end means it was consumed.
    // Advertise the trial only from a LOADED entitlement — on loading/error the
    // safe default is the paid copy (the Worker re-checks trial_end at initiate
    // anyway, so we must never promise a free day to a user it would charge).
    final entitlement = ref.watch(entitlementDetailProvider).asData?.value;
    final trialEligible =
        entitlement != null && entitlement.subscription?.trialEnd == null;

    final monthlyPrice = _monthlyPrice(
      ref.watch(appConfigProvider).asData?.value?.prices,
    );

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
                        for (
                          var i = 0;
                          i < PremiumScreen._perks.length;
                          i++
                        ) ...[
                          if (i > 0) const SizedBox(height: 14),
                          Row(
                            children: [
                              Icon(
                                PremiumScreen._perks[i].icon,
                                size: 22,
                                color: accent,
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Text(
                                  PremiumScreen._perks[i].text,
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
                                      text: '$monthlyPrice ',
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
                        // One free trial per user (server-enforced): the pill
                        // only shows when THIS user still has it. A repeat
                        // subscriber's mandate is a ₹199 TRANSACTION setup, so
                        // promising "free" here would charge them on a screen
                        // that said otherwise.
                        if (trialEligible)
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
                    label: trialEligible ? 'Start free trial' : 'Get Premium',
                    busy: purchaseBusy,
                    height: ArulTokens.ctaHeight54,
                    fontSize: 16,
                    onPressed: purchaseBusy
                        ? null
                        : () {
                            if (!AppConfig.hasBackend) {
                              // Defensive: unreachable in shipped builds
                              // (API_BASE_URL is always set). Kept for
                              // define-less local runs, where there is no
                              // Worker to initiate against.
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
                  // The trial-consumed variant is equally honest the other way:
                  // the server charges the full month upfront, so say so.
                  Text(
                    trialEligible
                        ? 'Free for 1 day, then $monthlyPrice/month. UPI '
                              'Autopay verifies your account with ₹2, refunded '
                              'instantly. Browsing stays free forever.'
                        : '$monthlyPrice charged today, then renews monthly '
                              'via UPI Autopay. Cancel anytime. Browsing stays '
                              'free forever.',
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
