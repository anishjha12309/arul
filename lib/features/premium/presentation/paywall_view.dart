import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../../../app/l10n/app_localizations.dart';
import '../../../core/haptics/arul_haptics.dart';
import '../../../core/upi/upi_apps.dart';
import '../../../theme/arul_tokens.dart';
import 'paywall_ornaments.dart';

/// A letter-spaced display label — "SUBSCRIPTION", "PREMIUM", "PER MONTH", "REFUNDED INSTANTLY".
///
/// These four are the only strings on the paywall whose TREATMENT is language-dependent, which is
/// why they route through here instead of a bare `Text`. English keeps Cinzel's or Lora's track,
/// plus the left padding that hands back the track applied after the LAST letter so the word
/// re-centres. Neither survives an Indic script — see [ArulTokens.paywallUntracked] — so both drop
/// together. Dropping only one leaves the label visibly off-centre.
class PaywallDisplayLabel extends StatelessWidget {
  const PaywallDisplayLabel({
    super.key,
    required this.text,
    required this.style,
    this.trackCompensation = 0,
  });

  final String text;

  /// The Latin style, tracking included.
  final TextStyle style;

  /// Left padding equal to [style]'s letterSpacing, given back only while the track is applied.
  final double trackCompensation;

  @override
  Widget build(BuildContext context) {
    final latin = Localizations.localeOf(context).languageCode == 'en';
    return Padding(
      padding: EdgeInsets.only(left: latin ? trackCompensation : 0),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: latin ? style : ArulTokens.paywallUntracked(style),
      ),
    );
  }
}

/// THE paywall — `design_handoff_arul_premium`, "holy authenticity".
///
/// One shell, two variants: the ₹199 monthly sell and the ₹2 free-trial sell.
/// Only the shrine panel's contents and the CTA label differ -> [trialEligible] is the one switch.
/// Localised into all six -> every string here comes from the ARBs.
/// The bundled Latin-subset faces need no guard: Flutter falls back per GLYPH, so an Indic run
/// lands on the system stack on its own. Only the letter-SPACED labels change treatment, via
/// [PaywallDisplayLabel] -> tracking is a Latin device and detaches Indic combining marks.
/// Owns no state beyond the social-proof rotation — entitlement, purchase and UPI live upstream.
class ArulPaywallView extends StatelessWidget {
  const ArulPaywallView({
    super.key,
    required this.trialEligible,
    required this.monthlyPrice,
    required this.purchaseBusy,
    required this.showSocialProof,
    this.onboardingVideo,
    required this.selectedUpiApp,
    required this.canChangeUpiApp,
    required this.onBack,
    required this.onChangeUpiApp,
    required this.onPurchase,
  });

  /// One free trial per user. Drives the panel — lead line + ₹2 + badge, or ₹199 + "PER MONTH".
  final bool trialEligible;

  /// "₹199" — from remote config, so a price test needs no release.
  final String monthlyPrice;

  final bool purchaseBusy;

  /// `feature_flags.show_social_proof`.
  final bool showSocialProof;

  /// The localised onboarding clip, resolved by [PremiumScreen] from the live locale.
  /// That locale IS the language the ad link carried.
  ///
  /// Non-null ONLY on the trial variant — the clip's script is "start your 1-day trial".
  /// This screen also sells ₹199/month to a spent-trial user, where that script would be a lie.
  /// It TAKES THE PLACE of the brand lockup, never stacks above it — both push the offer down.
  /// The offer panel moves up with it, out of the scrollable middle -> the price is read first.
  /// The clip caps its own height against the screen so that block always fits.
  final Widget? onboardingVideo;

  /// Null when no mandate-capable UPI app is installed -> the row goes, the CTA uses the hosted page.
  final UpiApp? selectedUpiApp;
  final bool canChangeUpiApp;

  final VoidCallback onBack;
  final VoidCallback onChangeUpiApp;
  final VoidCallback onPurchase;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    // Built once, placed in exactly ONE branch below — above the clip, or centred in the middle.
    final video = onboardingVideo;
    // The footer sits outside the middle's LayoutBuilder -> it reads the SCREEN, not the viewport.
    // Same intent: on a short phone the chrome gives back padding so the clip fits above the fold.
    final denseFooter = MediaQuery.sizeOf(context).height < 700;
    // The clip layout fits two blocks where the handoff had one -> the panel gives back its air.
    // Frame, ₹2 and badge keep every handoff dimension — only padding tightens.
    // `dense` tightens again on a short screen, where the clip at rest is non-negotiable.
    _ShrinePanel offerPanel(bool dense) => _ShrinePanel(
      padTop: trialEligible ? 24 : 26,
      compact: video != null,
      dense: dense,
      child: trialEligible
          ? _TrialOffer(monthlyPrice: monthlyPrice, dense: dense)
          : _MonthlyOffer(monthlyPrice: monthlyPrice),
    );
    return PaywallGround(
      child: Column(
        children: [
          // Pinned, so the way out stays reachable however far the sell scrolls.
          _NavRow(onBack: onBack),
          if (video == null) ...[
            _HeaderBlock(showSocialProof: showSocialProof),
            // The handoff's ~745pt page is SHORTER than the phone it lands on.
            // Rather than pool that slack above the footer, centre the offer between the pinned ends.
            // When the slack runs out it scrolls instead -> the CTA is pinned, not in this list.
            Expanded(
              child: _ScrollableMiddle(
                children: [offerPanel(false), const _FeatureRow()],
              ),
            ),
          ] else ...[
            // Clip layout: offer read FIRST, clip under it, features last.
            // All three SCROLL as one block between the pinned nav and the pinned CTA.
            // Pinning the offer and clip instead failed at 360x640dp — the pinned blocks alone
            // exceed the screen.
            // Flex children got zero and BOTH the clip and the feature row vanished behind a stripe.
            // Scrolling keeps the ordering promise -> the clip is fully on screen at rest, every size.
            // Only the features fall below the fold, and only when there is genuinely no room.
            // The clip is capped at a THIRD of the viewport -> it cannot crowd the price out.
            // On a tall screen that cap sits above its natural 16:9 height and does nothing.
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  // Everything between the pinned nav and the pinned CTA has this much room.
                  // Below ~420dp the ornament gives way: the pill goes, gaps close, the clip grows.
                  // The clip visible WITHOUT scrolling is a requirement, and padding is the only slack.
                  final h = constraints.maxHeight;
                  final dense = h < 420;
                  // A SECOND, higher threshold, only for the feature row.
                  // Between the two a phone fits the pill but not three medallions AND two label lines.
                  // A label sliced by the fold reads as broken; the same row 20% smaller reads designed.
                  // Separate thresholds are what stop a common 360x800 phone from losing the pill.
                  final tight = h < 520;
                  return SingleChildScrollView(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(minHeight: h),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          _HeaderCrest(
                            showSocialProof: showSocialProof && !dense,
                            dense: dense,
                          ),
                          // `tight`, not `dense` — the panel's padding is cheap to give back.
                          // `dense` also hides the social-proof pill, so splitting the two lets a
                          // 360x800 phone with system bars keep the pill AND the whole label.
                          offerPanel(tight),
                          // No height cap — the clip renders at its own 16:9, full width, everywhere.
                          // Capping here made a small phone show a letterbox band of forehead.
                          // The room comes out of `dense` above instead.
                          video,
                          _FeatureRow(tight: tight),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
          // Pinned: the buy decision must never be the thing below the fold.
          _Footer(
            dense: video != null && denseFooter,
            ctaLabel: trialEligible
                ? l10n.premiumCtaTrial
                : l10n.premiumCtaSubscribe,
            reassurance: trialEligible
                ? l10n.premiumReassuranceTrial
                : l10n.premiumReassurancePaid,
            busy: purchaseBusy,
            selectedUpiApp: selectedUpiApp,
            canChangeUpiApp: canChangeUpiApp,
            onChangeUpiApp: onChangeUpiApp,
            onPurchase: onPurchase,
          ),
        ],
      ),
    );
  }
}

/// The paywall while the entitlement read is in flight — the same shell and ground.
/// So resolving to one of the two offers is never a flash of a different screen.
class ArulPaywallLoading extends StatelessWidget {
  const ArulPaywallLoading({super.key, required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return PaywallGround(
      child: Column(
        children: [
          _NavRow(onBack: onBack),
          const Expanded(
            child: Center(
              child: SizedBox.square(
                dimension: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: ArulTokens.paywallMaroon,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Back ring + centred "SUBSCRIPTION", on the header ground.
class _NavRow extends StatelessWidget {
  const _NavRow({required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const PaywallOrnamentWing(
                ruleWidth: ArulTokens.paywallNavOrnamentRuleWidth,
                floretSize: ArulTokens.paywallNavFloretSize,
                gap: ArulTokens.paywallNavOrnamentGap,
              ),
              const SizedBox(width: ArulTokens.paywallNavTitleOrnamentGap),
              PaywallDisplayLabel(
                text: AppLocalizations.of(context).premiumNavTitle,
                style: ArulTokens.paywallNavTitle,
              ),
              const SizedBox(width: ArulTokens.paywallNavTitleOrnamentGap),
              const PaywallOrnamentWing(
                ruleWidth: ArulTokens.paywallNavOrnamentRuleWidth,
                floretSize: ArulTokens.paywallNavFloretSize,
                gap: ArulTokens.paywallNavOrnamentGap,
                mirrored: true,
              ),
            ],
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: Semantics(
              button: true,
              label: MaterialLocalizations.of(context).backButtonTooltip,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (_) => ArulHaptics.tap(),
                onTap: onBack,
                // The ring is 34; the touch target it sits in is 44.
                child: SizedBox.square(
                  dimension: ArulTokens.minHitTarget,
                  child: Center(
                    child: Container(
                      width: ArulTokens.paywallBackSize,
                      height: ArulTokens.paywallBackSize,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: ArulTokens.paywallBorderControl,
                        ),
                      ),
                      child: const Icon(
                        Icons.arrow_back,
                        size: 17,
                        color: ArulTokens.paywallInk,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Social-proof pill + temple divider — the part of the header both layouts share.
/// Tightens its gaps when a clip follows: that layout fits the panel AND the clip in one space.
class _HeaderCrest extends StatelessWidget {
  const _HeaderCrest({
    required this.showSocialProof,
    this.compact = true,
    this.dense = false,
  });

  final bool showSocialProof;
  final bool compact;

  /// Short screen: close the gaps to the minimum that still reads as spacing.
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: Padding(
        padding: EdgeInsets.only(top: dense ? 4 : (compact ? 10 : 14)),
        child: Column(
          children: [
            if (showSocialProof) const _SocialProofPill(),
            SizedBox(
              height: dense
                  ? 6
                  : (compact ? 12 : ArulTokens.paywallTempleDividerTopGap),
            ),
            const PaywallTempleDivider(),
            SizedBox(
              height: dense
                  ? 8
                  : (compact ? 14 : ArulTokens.paywallTempleDividerBottomGap),
            ),
          ],
        ),
      ),
    );
  }
}

/// The gold rule that closes the header.
class _HeaderHairline extends StatelessWidget {
  const _HeaderHairline();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(
      horizontal: ArulTokens.paywallHairlineInset,
    ),
    child: Container(
      height: 1,
      decoration: const BoxDecoration(
        gradient: ArulTokens.paywallHeaderHairline,
      ),
    ),
  );
}

/// The no-clip header, exactly as the handoff draws it.
class _HeaderBlock extends StatelessWidget {
  const _HeaderBlock({required this.showSocialProof});

  final bool showSocialProof;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _HeaderCrest(showSocialProof: showSocialProof, compact: false),
        const Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            0,
            20,
            ArulTokens.paywallBrandBottomPadding,
          ),
          child: _BrandLockup(),
        ),
        const _HeaderHairline(),
      ],
    );
  }
}

/// Centred when there is slack, scrollable when there is not.
/// Both layouts put whatever must never be clipped through here.
class _ScrollableMiddle extends StatelessWidget {
  const _ScrollableMiddle({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: children,
          ),
        ),
      ),
    );
  }
}

/// Gold-ruled "PREMIUM", the wordmark, the tagline.
class _BrandLockup extends StatelessWidget {
  const _BrandLockup();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const _BrandRule(),
            const SizedBox(width: ArulTokens.paywallBrandRuleGap),
            // Cinzel's .42em track applies AFTER the last letter too -> the word sits half right.
            // Giving that width back as left padding re-centres the ink.
            PaywallDisplayLabel(
              text: AppLocalizations.of(context).premiumEyebrow,
              style: ArulTokens.paywallEyebrow,
              trackCompensation: 5.46, // == paywallEyebrow.letterSpacing
            ),
            const SizedBox(width: ArulTokens.paywallBrandRuleGap),
            const _BrandRule(mirrored: true),
          ],
        ),
        const SizedBox(height: 4),
        Text('ARUL', style: ArulTokens.paywallWordmark),
        const SizedBox(height: ArulTokens.paywallBrandTaglineGap),
        PaywallLotusLabel(
          lotusSize: ArulTokens.paywallTaglineLotusSize,
          gap: ArulTokens.paywallTaglineOrnamentGap,
          child: Text(
            AppLocalizations.of(context).premiumTagline,
            textAlign: TextAlign.center,
            style: ArulTokens.paywallTagline,
          ),
        ),
      ],
    );
  }
}

class _BrandRule extends StatelessWidget {
  const _BrandRule({this.mirrored = false});

  /// The right rule runs gold→transparent, not the reverse -> both rules are darkest at the word.
  final bool mirrored;

  @override
  Widget build(BuildContext context) {
    return PaywallOrnamentWing(
      ruleWidth: ArulTokens.paywallBrandOrnamentRuleWidth,
      floretSize: ArulTokens.paywallBrandFloretSize,
      gap: ArulTokens.paywallBrandFloretGap,
      mirrored: mirrored,
    );
  }
}

/// The rotating social-proof pill — "`name` in `city` just applied a live wallpaper 🙏".
///
/// Names and cities are RANDOM from a fixed pool — no backend activity feed exists.
/// So it must never be presented as live data anywhere else (owner's call).
/// `feature_flags.show_social_proof` can retire it without a release.
/// Excluded from semantics — fake activity announced every four seconds is noise at best.
class _SocialProofPill extends StatefulWidget {
  const _SocialProofPill();

  @override
  State<_SocialProofPill> createState() => _SocialProofPillState();
}

class _SocialProofPillState extends State<_SocialProofPill> {
  static const _names = [
    'Arjun',
    'Priya',
    'Karthik',
    'Meena',
    'Suresh',
    'Divya',
    'Ravi',
    'Lakshmi',
    'Vijay',
    'Anitha',
    'Hari',
    'Deepa',
    'Manoj',
    'Kavya',
    'Senthil',
    'Ramya',
    'Naveen',
    'Devi',
  ];
  static const _cities = [
    'Chennai',
    'Madurai',
    'Coimbatore',
    'Bengaluru',
    'Mysuru',
    'Hyderabad',
    'Vijayawada',
    'Kochi',
    'Thrissur',
    'Salem',
    'Tiruchirappalli',
    'Vellore',
    'Tirupati',
    'Thanjavur',
    'Kozhikode',
    'Hubballi',
  ];

  final _rng = Random();
  Timer? _timer;

  /// The (name, city) PAIR, not a built sentence.
  ///
  /// Tamil, Telugu, Kannada and Malayalam all put the city first and attach the locative to it,
  /// so the word order is the translation's to decide -> the sentence is assembled in [build]
  /// from `premiumSocialProof`, never concatenated here.
  late (String, String) _who = _next(null);

  /// A fresh pair, re-rolled if it matches [prev] — the pool is small enough to collide.
  /// A "new" line that reads identically looks like the ticker froze.
  (String, String) _next((String, String)? prev) {
    (String, String) pick;
    do {
      pick = (
        _names[_rng.nextInt(_names.length)],
        _cities[_rng.nextInt(_cities.length)],
      );
    } while (pick == prev);
    return pick;
  }

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 4), (_) {
      setState(() => _who = _next(_who));
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final line = AppLocalizations.of(
      context,
    ).premiumSocialProof(_who.$1, _who.$2);
    return ExcludeSemantics(
      child: AnimatedSwitcher(
        duration: ArulTokens.chromeSettleIn,
        switchInCurve: ArulTokens.settleCurve,
        switchOutCurve: ArulTokens.settleCurve,
        child: Container(
          key: ValueKey(line),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: ArulTokens.paywallBorderPill),
            borderRadius: BorderRadius.circular(ArulTokens.pillRadius),
          ),
          child: Text(
            line,
            // TWO lines, not one. The longest pairing ("Tiruchirappalli" + a Kannada verb phrase)
            // ellipsised at 360dp, and English did the same at 1.3x text scale — a ticker that
            // ends in "..." reads as a bug, not as chrome. The pill grows into the header's slack;
            // in `dense` mode there is none, and the whole pill is dropped before it ever wraps.
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: ArulTokens.paywallPill,
          ),
        ),
      ),
    );
  }
}

/// The offer inside two crisp, parallel chamfered rules.
class _ShrinePanel extends StatelessWidget {
  const _ShrinePanel({
    required this.padTop,
    required this.child,
    this.compact = false,
    this.dense = false,
  });

  /// Short screen — see [ArulPaywallView].
  final bool dense;

  /// The handoff gives the monthly panel 26px of top padding and the trial 24 — its lead line pays.
  final double padTop;

  /// Give back the padding AROUND the panel so the clip has room beneath it.
  /// Never the frame, the price or the badge — those stay handoff-exact.
  final bool compact;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        ArulTokens.paywallPanelInset,
        dense ? 4 : (compact ? 10 : ArulTokens.paywallPanelTopGap),
        ArulTokens.paywallPanelInset,
        0,
      ),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          PaywallChamferedPanel(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                ArulTokens.paywallPanelContentInset,
                (dense ? padTop - 16 : (compact ? padTop - 10 : padTop)) +
                    ArulTokens.paywallPanelFrameStroke,
                ArulTokens.paywallPanelContentInset,
                dense
                    ? 7
                    : (compact ? 11 : ArulTokens.paywallPanelContentBottom),
              ),
              child: child,
            ),
          ),
        ],
      ),
    );
  }
}

/// Screen A — ₹199, "PER MONTH", the fixed fine print.
class _MonthlyOffer extends StatelessWidget {
  const _MonthlyOffer({required this.monthlyPrice});

  final String monthlyPrice;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        PriceLockup(price: monthlyPrice),
        const SizedBox(height: 10),
        // The trailing letter-space is trimmed the same way the eyebrow's is.
        PaywallRuledLabel(
          child: PaywallDisplayLabel(
            text: AppLocalizations.of(context).premiumPerMonthCaption,
            style: ArulTokens.paywallPriceCaption,
            trackCompensation: 3.92,
          ),
        ),
        const _PriceDivider(),
        // Contractually fixed — ships verbatim.
        Text(
          '$monthlyPrice/month via autopay. Cancel anytime.',
          textAlign: TextAlign.center,
          style: ArulTokens.paywallFinePrint,
        ),
      ],
    );
  }
}

/// Screen B — the ₹2 penny-drop, named as loudly as the design names it.
///
/// A UPI mandate setup costs a ₹2 PENNY_DROP that PhonePe reverses immediately.
/// The user still SEES ₹2 leave -> an unexplained debit on a "free" screen reads as a scam.
class _TrialOffer extends StatelessWidget {
  const _TrialOffer({required this.monthlyPrice, this.dense = false});

  final String monthlyPrice;

  /// Short screen: scale the price lockup down and drop the ornament under it.
  /// Nothing contractual moves — lead line, badge and "Then ₹199/month" ship verbatim at every size.
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text.rich(
          TextSpan(
            // 1 day, not 7 — the server grants exactly TRIAL_DAYS=1 and debits at trial end.
            // Promising more than the mandate honours is how you get chargebacks.
            text: AppLocalizations.of(context).premiumTrialLeadPrefix,
            children: [
              TextSpan(
                text: monthlyPrice,
                style: const TextStyle(
                  decoration: TextDecoration.lineThrough,
                  decorationThickness: 1.5,
                  color: ArulTokens.paywallInkFaint,
                ),
              ),
            ],
          ),
          textAlign: TextAlign.center,
          style: ArulTokens.paywallLead,
        ),
        const SizedBox(height: ArulTokens.paywallTrialLeadGap),
        // PriceLockup centres the rupee from a per-glyph ink table -> a uniform scale keeps that.
        // A type-size change would not -> FittedBox, never a smaller font.
        if (dense)
          SizedBox(
            height: ArulTokens.paywallDensePriceHeight,
            child: const FittedBox(
              fit: BoxFit.contain,
              child: PriceLockup(price: '₹2'),
            ),
          )
        else
          const PriceLockup(price: '₹2'),
        const SizedBox(height: ArulTokens.paywallTrialPriceGap),
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: ArulTokens.paywallTrialBadgeVerticalPadding,
          ),
          decoration: BoxDecoration(
            color: ArulTokens.paywallMaroon,
            borderRadius: BorderRadius.circular(ArulTokens.pillRadius),
          ),
          child: PaywallDisplayLabel(
            text: AppLocalizations.of(context).premiumRefundedBadge,
            style: ArulTokens.paywallBadge,
            trackCompensation: 2.3,
          ),
        ),
        if (!dense) const _PriceDivider() else const SizedBox(height: 10),
        // Contractually fixed — ships verbatim.
        Text(
          AppLocalizations.of(context).premiumTrialFinePrint(monthlyPrice),
          textAlign: TextAlign.center,
          style: ArulTokens.paywallFinePrint,
        ),
      ],
    );
  }
}

class _PriceDivider extends StatelessWidget {
  const _PriceDivider();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.only(
      top: ArulTokens.paywallPriceDividerTopGap,
      bottom: ArulTokens.paywallPriceDividerBottomGap,
    ),
    child: PaywallOrnamentImage(
      ornament: PaywallOrnament.priceDivider,
      width: ArulTokens.paywallPriceOrnamentWidth,
    ),
  );
}

/// The price — a rupee sign set optically smaller beside the amount, and genuinely centred on it.
///
/// A text box is positioned by the font's ascent and descent, not by where the ink falls.
/// Gelasio carries old-style figures: 1 and 2 stop at x-height, 3/5/7/9 drop below the baseline.
/// So the amount's ink sits low in its box while the full-height ₹ sits centred in its own.
/// Centring the BOXES floats the rupee ~8px high on "₹199" -> never a plain centre-aligned `Row`.
/// This aligns the BASELINES, then shifts the rupee by the difference between the two ink centres.
/// [_gelasioInk] is the glyph table it is solved from -> any amount config sends stays centred.
class PriceLockup extends StatelessWidget {
  const PriceLockup({super.key, required this.price});

  /// "₹199" — a leading rupee sign followed by the amount.
  final String price;

  /// Ink extents in `em` from `Gelasio-Regular.ttf` (upem 2048), as `(yMin, yMax)` about the baseline.
  /// Regenerate with tools/build-fonts.py if that file is rebuilt from a different upstream.
  static const Map<String, (double, double)> _gelasioInk = {
    '0': (-0.014160, 0.588379),
    '1': (0.000000, 0.580566),
    '2': (0.000000, 0.588379),
    '3': (-0.192383, 0.588379),
    '4': (-0.160156, 0.587402),
    '5': (-0.191406, 0.580566),
    '6': (-0.014160, 0.746582),
    '7': (-0.170898, 0.581055),
    '8': (-0.014648, 0.707520),
    '9': (-0.172363, 0.588379),
    '.': (-0.009766, 0.125488),
    ',': (-0.175781, 0.125488),
    '₹': (0.000000, 0.693359),
  };

  /// Where a string's ink centre sits ABOVE the baseline, in `em`; unknown characters are ignored.
  /// An entirely unknown string falls back to half the rupee's height — what box-centring would give.
  static double inkCentreEm(String text) {
    double? low, high;
    for (var i = 0; i < text.length; i++) {
      final ink = _gelasioInk[text[i]];
      if (ink == null) continue;
      low = low == null ? ink.$1 : min(low, ink.$1);
      high = high == null ? ink.$2 : max(high, ink.$2);
    }
    if (low == null || high == null) return _gelasioInk['₹']!.$2 / 2;
    return (low + high) / 2;
  }

  /// How far the rupee must move (positive = down) to meet the amount's ink centre on one baseline.
  static double rupeeOffset(String symbol, String amount) =>
      inkCentreEm(symbol) * ArulTokens.paywallRupeeSize -
      inkCentreEm(amount) * ArulTokens.paywallAmountSize;

  @override
  Widget build(BuildContext context) {
    // Everything up to the first digit is the symbol; the rest is the amount.
    final split = price.indexOf(RegExp(r'[0-9]'));
    final symbol = split <= 0 ? '₹' : price.substring(0, split);
    final amount = split <= 0 ? price : price.substring(split);

    const numeral = TextStyle(
      fontFamily: ArulTokens.paywallNumeralFamily,
      color: ArulTokens.paywallMaroon,
      // height 1 keeps each box the size of its own type -> the Row is the lockup, no stray leading.
      height: 1,
      leadingDistribution: TextLeadingDistribution.even,
    );

    return Row(
      mainAxisSize: MainAxisSize.min,
      // Baselines first — Transform.translate reports its child's baseline unshifted, so it paints.
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Transform.translate(
          offset: Offset(0, rupeeOffset(symbol, amount)),
          child: Text(
            symbol,
            style: numeral.copyWith(fontSize: ArulTokens.paywallRupeeSize),
          ),
        ),
        const SizedBox(width: ArulTokens.paywallPriceGap),
        Text(
          amount,
          style: numeral.copyWith(fontSize: ArulTokens.paywallAmountSize),
        ),
      ],
    );
  }
}

class _FeatureRow extends StatelessWidget {
  const _FeatureRow({this.tight = false});

  /// Short screen: 20% off the medallions and the gaps. Never the labels — they are the content.
  final bool tight;

  @override
  Widget build(BuildContext context) {
    return Padding(
      // Tighter than the handoff's 24/6 — the clip below may never shrink (owner's call).
      // So this row is where the vertical budget comes from; three icons and two words afford it.
      // Without it the second line of "Unlimited HD Wallpapers" was sliced by the fold at 360x640.
      padding: EdgeInsets.fromLTRB(24, tight ? 8 : 12, 24, 4),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: _Feature(
                icon: PaywallOrnament.wallpapers,
                label: AppLocalizations.of(context).premiumFeatureWallpapers,
                tight: tight,
              ),
            ),
            const _FeatureDivider(),
            Expanded(
              child: _Feature(
                icon: PaywallOrnament.ringtones,
                label: AppLocalizations.of(context).premiumFeatureRingtones,
                tight: tight,
              ),
            ),
            const _FeatureDivider(),
            Expanded(
              child: _Feature(
                icon: PaywallOrnament.daily,
                label: AppLocalizations.of(context).premiumFeatureDaily,
                tight: tight,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FeatureDivider extends StatelessWidget {
  const _FeatureDivider();

  @override
  Widget build(BuildContext context) =>
      const SizedBox(width: 1, child: PaywallDottedLine(vertical: true));
}

class _Feature extends StatelessWidget {
  const _Feature({required this.icon, required this.label, this.tight = false});

  final PaywallOrnament icon;
  final String label;
  final bool tight;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Column(
        children: [
          Container(
            width: tight ? 38 : ArulTokens.paywallMedallionSize,
            height: tight ? 38 : ArulTokens.paywallMedallionSize,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: ArulTokens.paywallMedallionFill,
              border: Border.all(
                color: ArulTokens.paywallGold600,
                width: ArulTokens.paywallMedallionBorder,
              ),
            ),
            child: Center(
              child: PaywallOrnamentImage(
                ornament: icon,
                width: tight ? 25 : ArulTokens.paywallFeatureArtSize,
              ),
            ),
          ),
          SizedBox(height: tight ? 4 : 6),
          Text(
            label,
            textAlign: TextAlign.center,
            style: ArulTokens.paywallFeatureLabel,
          ),
        ],
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({
    this.dense = false,
    required this.ctaLabel,
    required this.reassurance,
    required this.busy,
    required this.selectedUpiApp,
    required this.canChangeUpiApp,
    required this.onChangeUpiApp,
    required this.onPurchase,
  });

  /// Short screen — give back the outer padding, never the CTA's own height.
  final bool dense;
  final String ctaLabel;
  final String reassurance;
  final bool busy;
  final UpiApp? selectedUpiApp;
  final bool canChangeUpiApp;
  final VoidCallback onChangeUpiApp;
  final VoidCallback onPurchase;

  @override
  Widget build(BuildContext context) {
    final app = selectedUpiApp;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        24,
        dense ? 8 : 18,
        24,
        dense ? 2 : ArulTokens.paywallFooterBottomPadding,
      ),
      child: Column(
        children: [
          if (app != null) ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Flexible(
                  child: Text(
                    AppLocalizations.of(context).premiumSelectedUpiApp,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ArulTokens.paywallUpiLabel,
                  ),
                ),
                const SizedBox(width: 12),
                // A Spacer claims its share of the free space and ellipsises a name that fits.
                // So Flexible, not Expanded, and NO Spacer between the two.
                Flexible(
                  child: _UpiChip(
                    app: app,
                    // A single installed app is a fact, not a choice — no caret, no tap target.
                    canChange: canChangeUpiApp && !busy,
                    onTap: onChangeUpiApp,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
          ],
          ShrineCta(
            label: ctaLabel,
            busy: busy,
            onPressed: busy ? null : onPurchase,
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const PaywallOrnamentImage(
                ornament: PaywallOrnament.lotus,
                width: ArulTokens.paywallFooterLotusSize,
              ),
              const SizedBox(width: ArulTokens.paywallFooterLotusGap),
              Flexible(
                child: Text(
                  reassurance,
                  textAlign: TextAlign.center,
                  style: ArulTokens.paywallReassurance,
                ),
              ),
              const SizedBox(width: ArulTokens.paywallFooterLotusGap),
              const PaywallOrnamentImage(
                ornament: PaywallOrnament.lotus,
                width: ArulTokens.paywallFooterLotusSize,
              ),
            ],
          ),
          const SizedBox(height: ArulTokens.paywallFooterRuleGap),
          const PaywallOrnamentImage(
            ornament: PaywallOrnament.footerRule,
            width: ArulTokens.paywallFooterRuleWidth,
          ),
          // The audience is not payment-literate -> no cancel affordance during the wait, on purpose.
          // The provider's resume checkpoint resolves success or failure within ~2s of the UPI return.
        ],
      ),
    );
  }
}

/// The chosen UPI app as a white pill: its own icon, its own name, a caret.
class _UpiChip extends StatelessWidget {
  const _UpiChip({
    required this.app,
    required this.canChange,
    required this.onTap,
  });

  final UpiApp app;
  final bool canChange;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final icon = app.icon;
    return GestureDetector(
      onTap: canChange ? onTap : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: ArulTokens.paywallBorderControl),
          borderRadius: BorderRadius.circular(ArulTokens.pillRadius),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // The app's REAL mark from PackageManager — the handoff fakes one, having no PM.
            if (icon == null)
              const Icon(
                Icons.account_balance_wallet_outlined,
                size: 18,
                color: ArulTokens.paywallInkMuted,
              )
            else
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.memory(
                  icon,
                  width: 20,
                  height: 20,
                  gaplessPlayback: true,
                ),
              ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                app.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ArulTokens.paywallUpiName,
              ),
            ),
            if (canChange) ...[
              const SizedBox(width: 6),
              const Icon(
                Icons.arrow_drop_down,
                size: 16,
                color: ArulTokens.paywallInkMuted,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The buy button — a maroon gradient pill under a gold rim, lifted by a shadow and a top highlight.
///
/// Deliberately NOT [CtaButton]: that is the app's green primary, and this palette is the handoff's.
class ShrineCta extends StatefulWidget {
  const ShrineCta({
    super.key,
    required this.label,
    required this.busy,
    required this.onPressed,
    this.bottomLotus = false,
    this.labelStyle,
  });

  final String label;
  final bool busy;
  final VoidCallback? onPressed;
  final bool bottomLotus;
  final TextStyle? labelStyle;

  @override
  State<ShrineCta> createState() => _ShrineCtaState();
}

class _ShrineCtaState extends State<ShrineCta> {
  bool _pressed = false;

  bool get _enabled => widget.onPressed != null && !widget.busy;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: _enabled,
      label: widget.label,
      child: GestureDetector(
        key: const ValueKey('shrine-cta'),
        onTapDown: _enabled
            ? (_) {
                // The buy decision — the weightiest press in the app.
                ArulHaptics.firm();
                setState(() => _pressed = true);
              }
            : null,
        onTapUp: _enabled ? (_) => setState(() => _pressed = false) : null,
        onTapCancel: _enabled ? () => setState(() => _pressed = false) : null,
        onTap: _enabled ? widget.onPressed : null,
        child: AnimatedScale(
          scale: _pressed ? ArulTokens.paywallPressScale : 1,
          duration: ArulTokens.paywallPress,
          curve: ArulTokens.settleCurve,
          child: Opacity(
            opacity: _enabled || widget.busy ? 1 : 0.5,
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.center,
              children: [
                Container(
                  width: double.infinity,
                  // Height comes from the 16px padding, exactly as the handoff sizes it.
                  // The 22px spinner is within half a pixel of the label's box -> no resize when busy.
                  padding: const EdgeInsets.symmetric(
                    vertical: ArulTokens.paywallCtaPadding,
                  ),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    gradient: ArulTokens.paywallCtaFill,
                    border: Border.all(color: ArulTokens.paywallGold500),
                    borderRadius: BorderRadius.circular(ArulTokens.pillRadius),
                    boxShadow: ArulTokens.paywallCtaShadow,
                  ),
                  foregroundDecoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(ArulTokens.pillRadius),
                    gradient: ArulTokens.paywallCtaTopLip,
                  ),
                  child: widget.busy
                      ? const SizedBox.square(
                          key: ValueKey('shrine-cta-progress'),
                          dimension: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.4,
                            color: ArulTokens.paywallOnCta,
                          ),
                        )
                      // The buy button may NEVER ellipsise — "இலவச சோதனையைத் தொடங்…" is not a
                      // thing anyone taps. It scales down instead of truncating or wrapping:
                      // wrapping would change the button's height, and the busy spinner is sized
                      // to within half a pixel of a ONE-line label so the CTA cannot resize when
                      // tapped. `scaleDown` is a no-op whenever the label already fits, so English
                      // renders at exactly the handoff size.
                      : Padding(
                          // Clears the florets pinned at both ends -> the label shrinks to the gap
                          // between them, never underneath them.
                          padding: const EdgeInsets.symmetric(
                            horizontal:
                                ArulTokens.paywallCtaOrnamentInset +
                                ArulTokens.paywallCtaFloretSize +
                                ArulTokens.paywallCtaLabelGap,
                          ),
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              widget.label,
                              maxLines: 1,
                              style:
                                  widget.labelStyle ??
                                  ArulTokens.paywallCtaLabel,
                            ),
                          ),
                        ),
                ),
                if (!widget.busy) ...[
                  const Positioned(
                    left: ArulTokens.paywallCtaOrnamentInset,
                    child: PaywallOrnamentImage(
                      ornament: PaywallOrnament.floretGold,
                      width: ArulTokens.paywallCtaFloretSize,
                    ),
                  ),
                  const Positioned(
                    right: ArulTokens.paywallCtaOrnamentInset,
                    child: PaywallOrnamentImage(
                      ornament: PaywallOrnament.floretGold,
                      width: ArulTokens.paywallCtaFloretSize,
                    ),
                  ),
                  if (widget.bottomLotus)
                    const Positioned(
                      bottom: -ArulTokens.paywallCtaLotusRise,
                      child: PaywallOrnamentImage(
                        ornament: PaywallOrnament.lotus,
                        width: ArulTokens.paywallCtaLotusSize,
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
