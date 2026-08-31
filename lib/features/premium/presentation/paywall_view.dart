import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../../../core/haptics/arul_haptics.dart';
import '../../../core/upi/upi_apps.dart';
import '../../../theme/arul_tokens.dart';
import 'paywall_ornaments.dart';

/// THE paywall — `design_handoff_arul_premium`, "holy authenticity".
///
/// One shell, two variants: the ₹199 monthly sell and the ₹2 free-trial sell.
/// Only the shrine panel's contents and the CTA label differ, which is why
/// [trialEligible] is the single switch and everything else is shared.
///
/// English-only by product decision (CLAUDE.md §5 / the handoff), so no string
/// here goes through the ARBs — and the bundled Latin-subset paywall fonts can
/// never be asked for a script they do not carry.
///
/// Owns no state beyond the social-proof rotation: entitlement, purchase and
/// UPI selection all live in [PremiumScreen], which passes them down.
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

  /// One free trial per user. Drives the whole panel: lead line + ₹2 + badge
  /// when true, ₹199 + "PER MONTH" when not.
  final bool trialEligible;

  /// "₹199" — from remote config, so a price test needs no release.
  final String monthlyPrice;

  final bool purchaseBusy;

  /// `feature_flags.show_social_proof`.
  final bool showSocialProof;

  /// The localised onboarding clip, resolved by [PremiumScreen] from the app's
  /// live locale — which IS the language the ad link carried.
  ///
  /// Non-null ONLY on the trial variant (owner's call): this screen also sells
  /// ₹199/month to users whose trial is spent, and the clip's whole script is
  /// "start your 1-day trial". When it is present it TAKES THE PLACE of the
  /// brand lockup rather than being added above it — the lockup's Cinzel cannot
  /// render Indic scripts anyway, and stacking both would push the offer below
  /// the fold on most phones.
  final Widget? onboardingVideo;

  /// Null when no mandate-capable UPI app is installed — the row disappears
  /// and the CTA falls through to the hosted-page flow.
  final UpiApp? selectedUpiApp;
  final bool canChangeUpiApp;

  final VoidCallback onBack;
  final VoidCallback onChangeUpiApp;
  final VoidCallback onPurchase;

  @override
  Widget build(BuildContext context) {
    return PaywallGround(
      child: Column(
        children: [
          // Pinned, so the way out stays reachable however far the sell
          // scrolls.
          // Pinned, so the way out stays reachable however far the sell
          // scrolls.
          _NavRow(onBack: onBack),
          _HeaderBlock(
            showSocialProof: showSocialProof,
            onboardingVideo: onboardingVideo,
          ),
          // The handoff draws one ~745pt page, which is SHORTER than the phone
          // it lands on. Rather than let that slack pool into a hole above the
          // footer, the offer block is centred in what the two pinned ends
          // leave — the same air above the panel as below the features. When
          // the slack runs out (small screen, large text) the block scrolls
          // instead, which is why the CTA is pinned and not in this list.
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) => SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _ShrinePanel(
                        padTop: trialEligible ? 24 : 26,
                        child: trialEligible
                            ? _TrialOffer(monthlyPrice: monthlyPrice)
                            : _MonthlyOffer(monthlyPrice: monthlyPrice),
                      ),
                      const _FeatureRow(),
                    ],
                  ),
                ),
              ),
            ),
          ),
          // Pinned: the buy decision must never be the thing below the fold.
          _Footer(
            ctaLabel: trialEligible ? 'Start Free Trial' : 'Subscribe Now',
            reassurance: trialEligible
                ? '₹2 verification, refunded instantly · Cancel anytime'
                : 'Secured by UPI Autopay · Cancel anytime in one tap',
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

/// The paywall while the entitlement read is still in flight — the same shell
/// and ground, so resolving to one of the two offers is not a flash of a
/// different screen.
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

// ─── Header ──────────────────────────────────────────────────────────────────

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
          const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              PaywallOrnamentWing(
                ruleWidth: ArulTokens.paywallNavOrnamentRuleWidth,
                floretSize: ArulTokens.paywallNavFloretSize,
                gap: ArulTokens.paywallNavOrnamentGap,
              ),
              SizedBox(width: ArulTokens.paywallNavTitleOrnamentGap),
              Text('SUBSCRIPTION', style: ArulTokens.paywallNavTitle),
              SizedBox(width: ArulTokens.paywallNavTitleOrnamentGap),
              PaywallOrnamentWing(
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

/// Social-proof pill + brand lockup, closed by the gold hairline.
class _HeaderBlock extends StatelessWidget {
  const _HeaderBlock({required this.showSocialProof, this.onboardingVideo});

  final bool showSocialProof;

  /// When present, stands in for [_BrandLockup] — see [ArulPaywallView].
  final Widget? onboardingVideo;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: Padding(
        padding: const EdgeInsets.only(top: 14),
        child: Column(
          children: [
            if (showSocialProof) const _SocialProofPill(),
            const SizedBox(height: ArulTokens.paywallTempleDividerTopGap),
            const PaywallTempleDivider(),
            const SizedBox(height: ArulTokens.paywallTempleDividerBottomGap),
            // The clip replaces the lockup; it carries its own gutters and
            // bottom gap so the hairline below stays where the handoff put it.
            if (onboardingVideo case final video?)
              video
            else
              const Padding(
                padding: EdgeInsets.fromLTRB(
                  20,
                  0,
                  20,
                  ArulTokens.paywallBrandBottomPadding,
                ),
                child: _BrandLockup(),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: ArulTokens.paywallHairlineInset,
              ),
              child: Container(
                height: 1,
                decoration: const BoxDecoration(
                  gradient: ArulTokens.paywallHeaderHairline,
                ),
              ),
            ),
          ],
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
            // Cinzel's .42em track is applied AFTER the last letter too, so the
            // word would sit half a track right of centre. Giving that width
            // back as left padding re-centres the ink.
            Padding(
              padding: const EdgeInsets.only(
                left: 5.46, // == paywallEyebrow.letterSpacing
              ),
              child: Text('PREMIUM', style: ArulTokens.paywallEyebrow),
            ),
            const SizedBox(width: ArulTokens.paywallBrandRuleGap),
            const _BrandRule(mirrored: true),
          ],
        ),
        const SizedBox(height: 4),
        Text('ARUL', style: ArulTokens.paywallWordmark),
        const SizedBox(height: ArulTokens.paywallBrandTaglineGap),
        const PaywallLotusLabel(
          lotusSize: ArulTokens.paywallTaglineLotusSize,
          gap: ArulTokens.paywallTaglineOrnamentGap,
          child: Text(
            'Divine grace, every day',
            style: ArulTokens.paywallTagline,
          ),
        ),
      ],
    );
  }
}

class _BrandRule extends StatelessWidget {
  const _BrandRule({this.mirrored = false});

  /// The right-hand rule runs gold→transparent instead of transparent→gold, so
  /// both rules are darkest against the word.
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

/// The rotating social-proof pill — "`name` in `city` just applied a live
/// wallpaper 🙏".
///
/// Names and cities are RANDOM from a fixed pool (owner's call, 2026-08-11):
/// no backend activity feed exists, so this must never be presented as live
/// data anywhere else, and `feature_flags.show_social_proof` can retire it
/// without a release.
///
/// Excluded from semantics — it is decoration, and a screen reader announcing
/// fake activity every four seconds would be noise at best.
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
  late String _line = _next(null);

  /// A fresh line, re-rolled if it matches [prev] — the pool is small enough
  /// to collide, and a "new" line that reads identically looks like the ticker
  /// froze.
  String _next(String? prev) {
    String line;
    do {
      line =
          '${_names[_rng.nextInt(_names.length)]} in '
          '${_cities[_rng.nextInt(_cities.length)]} '
          'just applied a live wallpaper 🙏';
    } while (line == prev);
    return line;
  }

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 4), (_) {
      setState(() => _line = _next(_line));
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: AnimatedSwitcher(
        duration: ArulTokens.chromeSettleIn,
        switchInCurve: ArulTokens.settleCurve,
        switchOutCurve: ArulTokens.settleCurve,
        child: Container(
          key: ValueKey(_line),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: ArulTokens.paywallBorderPill),
            borderRadius: BorderRadius.circular(ArulTokens.pillRadius),
          ),
          child: Text(
            _line,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: ArulTokens.paywallPill,
          ),
        ),
      ),
    );
  }
}

// ─── The shrine panel ────────────────────────────────────────────────────────

/// The offer inside two crisp, parallel chamfered rules.
class _ShrinePanel extends StatelessWidget {
  const _ShrinePanel({required this.padTop, required this.child});

  /// The handoff gives the monthly panel 26px of top padding and the trial
  /// panel 24 — the trial's extra lead line makes up the difference.
  final double padTop;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        ArulTokens.paywallPanelInset,
        ArulTokens.paywallPanelTopGap,
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
                padTop + ArulTokens.paywallPanelFrameStroke,
                ArulTokens.paywallPanelContentInset,
                ArulTokens.paywallPanelContentBottom,
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
        const PaywallRuledLabel(
          child: Padding(
            padding: EdgeInsets.only(left: 3.92),
            child: Text('PER MONTH', style: ArulTokens.paywallPriceCaption),
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
/// Setting up a UPI mandate costs a ₹2 PENNY_DROP that PhonePe reverses
/// immediately, but the user still SEES ₹2 leave their account, and an
/// unexplained debit on a screen that said "free" reads as a scam.
class _TrialOffer extends StatelessWidget {
  const _TrialOffer({required this.monthlyPrice});

  final String monthlyPrice;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text.rich(
          TextSpan(
            // 1 day, not 7: the server grants exactly TRIAL_DAYS=1
            // (payments.ts) and debits the month at trial end. Promising more
            // than the mandate honours is how you get chargebacks.
            text: 'Start your 1-day FREE trial for ',
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
          child: const Padding(
            padding: EdgeInsets.only(left: 2.3),
            child: Text('REFUNDED INSTANTLY', style: ArulTokens.paywallBadge),
          ),
        ),
        const _PriceDivider(),
        // Contractually fixed — ships verbatim.
        Text(
          'Then $monthlyPrice/month via autopay. Cancel anytime.',
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

/// The price, as a rupee sign set optically smaller beside the amount — and
/// genuinely centred against it.
///
/// **Why this is not just a `Row` with `CrossAxisAlignment.center`.** That is
/// what the HTML reference does (`align-items:center` over two `line-height:1`
/// boxes) and it does NOT centre the two glyphs: a text box is positioned by
/// the font's ascent and descent, not by where the ink actually falls. Gelasio
/// carries Georgia's old-style figures — 1 and 2 stop at x-height, 3/5/7/9
/// drop below the baseline — so the amount's ink sits low in its box while the
/// full-height ₹ sits centred in its own. Centring the BOXES leaves the rupee
/// floating ~8px high on "₹199", which is exactly how the reference renders.
///
/// So this aligns the baselines and then shifts the rupee by the difference
/// between the two ink centres, measured from the real font. The result is the
/// handoff's stated intent — "rupee glyph optically smaller, vertically
/// centered against the digits" — rather than its HTML approximation.
///
/// [_gelasioInk] is the glyph table this is solved from, so the price stays
/// centred for ANY amount remote config sends, not just ₹199 and ₹2.
class PriceLockup extends StatelessWidget {
  const PriceLockup({super.key, required this.price});

  /// "₹199" — a leading rupee sign followed by the amount.
  final String price;

  /// Ink extents in `em`, from `assets/fonts/Gelasio-Regular.ttf` (upem 2048),
  /// as `(yMin, yMax)` about the baseline. Regenerate with tools/build-fonts.py
  /// if that file is ever rebuilt from a different upstream.
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

  /// Where a string's ink centre sits ABOVE the baseline, in `em`. Unknown
  /// characters are ignored; an entirely unknown string falls back to half the
  /// rupee's height, which is the same answer box-centring would have given.
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

  /// How far the rupee must move (positive = down) for its ink centre to meet
  /// the amount's, with both sitting on a shared baseline.
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
      // height 1 keeps each box the size of its own type, so the Row is as
      // tall as the lockup and no stray leading pads the panel.
      height: 1,
      leadingDistribution: TextLeadingDistribution.even,
    );

    return Row(
      mainAxisSize: MainAxisSize.min,
      // Baselines first — Transform.translate below reports its child's
      // baseline unshifted, so the offset is applied purely at paint.
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

// ─── Feature row ─────────────────────────────────────────────────────────────

class _FeatureRow extends StatelessWidget {
  const _FeatureRow();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.fromLTRB(24, 24, 24, 6),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: _Feature(
                icon: PaywallOrnament.wallpapers,
                label: 'Unlimited HD Wallpapers',
              ),
            ),
            _FeatureDivider(),
            Expanded(
              child: _Feature(
                icon: PaywallOrnament.ringtones,
                label: 'Devotional Ringtones',
              ),
            ),
            _FeatureDivider(),
            Expanded(
              child: _Feature(
                icon: PaywallOrnament.daily,
                label: 'Daily New Content',
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
  const _Feature({required this.icon, required this.label});

  final PaywallOrnament icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Column(
        children: [
          Container(
            width: ArulTokens.paywallMedallionSize,
            height: ArulTokens.paywallMedallionSize,
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
                width: ArulTokens.paywallFeatureArtSize,
              ),
            ),
          ),
          const SizedBox(height: 8),
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

// ─── Footer ──────────────────────────────────────────────────────────────────

class _Footer extends StatelessWidget {
  const _Footer({
    required this.ctaLabel,
    required this.reassurance,
    required this.busy,
    required this.selectedUpiApp,
    required this.canChangeUpiApp,
    required this.onChangeUpiApp,
    required this.onPurchase,
  });

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
      padding: const EdgeInsets.fromLTRB(
        24,
        18,
        24,
        ArulTokens.paywallFooterBottomPadding,
      ),
      child: Column(
        children: [
          if (app != null) ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Flexible(
                  child: Text(
                    'Selected UPI App',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ArulTokens.paywallUpiLabel,
                  ),
                ),
                const SizedBox(width: 12),
                // Flexible, not Expanded, and no Spacer between the two: a
                // Spacer claims its share of the free space and leaves the
                // chip ellipsising a name that had room to fit.
                Flexible(
                  child: _UpiChip(
                    app: app,
                    // A single installed app is a fact, not a choice — no
                    // caret, no tap target.
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
          // No cancel affordance during the wait ON PURPOSE: the audience is
          // not payment-literate, so the app decides the outcome itself — the
          // resume checkpoint in the provider resolves success or failure
          // within ~2s of returning from the UPI app.
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
            // The app's REAL mark, from PackageManager — the handoff fakes a
            // PhonePe square because the browser has no package manager.
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

/// The buy button: a maroon gradient pill under a gold rim, lifted by its own
/// shadow and an inner top highlight.
///
/// Deliberately NOT [CtaButton] — that is the app's green primary, and this
/// screen's whole palette is the handoff's, not the app ladder's.
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
                  // Height comes from the 16px padding, exactly as the handoff
                  // sizes it — and the 22px spinner is within half a pixel of the
                  // label's line box, so the pill does not resize while busy.
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
                      : Text(
                          widget.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style:
                              widget.labelStyle ?? ArulTokens.paywallCtaLabel,
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
