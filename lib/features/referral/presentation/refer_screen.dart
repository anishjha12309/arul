import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app/widgets/cta_button.dart';
import '../../../theme/arul_tokens.dart';

/// Refer & Earn. Design-only pass (design_handoff_arul spec, "Refer & Earn"):
/// one warm silk hero card with the WhatsApp CTA, a rewards summary card, a
/// numbered "how it works" card, and a quiet empty state below.
///
/// No referral/share logic yet — the WhatsApp button is a visual CTA only
/// (see TODO below) and "Rewards earned" is hardcoded to "0 days" until the
/// backend ships.
///
/// `featured_seasonal_and_gifts` (the spec's icon) has no Material equivalent
/// in Flutter's icon set — substituted with [Icons.card_giftcard_rounded].
class ReferScreen extends StatelessWidget {
  const ReferScreen({super.key});

  static const _steps = [
    (n: '1', text: 'Share your link with friends and family'),
    (n: '2', text: 'They install Arul and subscribe to premium'),
    (n: '3', text: '30 days of free premium lands in your account'),
  ];

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final bg = isDark ? ArulTokens.darkSurface : ArulTokens.ivory;
    final textPrimary = isDark ? ArulTokens.darkText : ArulTokens.lightText;
    final heroSubText = isDark
        ? ArulTokens.darkBodyWarm
        : ArulTokens.lightSecondary;
    final accent = isDark ? ArulTokens.gold : ArulTokens.maroon;
    final heroBorder = isDark
        ? ArulTokens.goldBorder35
        : ArulTokens.goldBorder40;
    final heroGradient = isDark ? ArulTokens.silkDark : ArulTokens.silkLight;
    final cardBg = isDark ? ArulTokens.cardBgDark04 : ArulTokens.cardBgLight;
    final cardBorder = isDark
        ? ArulTokens.cardBorderDark09
        : ArulTokens.cardBorderLight;
    final rewardValueColor = isDark ? ArulTokens.gold : ArulTokens.maroon;
    final stepNumberBg = isDark
        ? ArulTokens.goldTintFill14
        : ArulTokens.maroonTintFill08;
    final stepText = isDark ? ArulTokens.darkBodyWarm : ArulTokens.lightBody;
    final emptyIconColor = isDark
        ? ArulTokens.darkText.withValues(alpha: 0.3)
        : ArulTokens.lightText.withValues(alpha: 0.25);
    final emptyTextColor = isDark
        ? ArulTokens.darkMuted
        : ArulTokens.lightSecondary;

    return Scaffold(
      backgroundColor: bg,
      body: SafeArea(
        child: Column(
          children: [
            // Header: back arrow + Marcellus title. README > Refer & Earn.
            Padding(
              padding: const EdgeInsets.fromLTRB(
                ArulTokens.screenPadding - 4,
                6,
                ArulTokens.screenPadding,
                10,
              ),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => context.pop(),
                    icon: Icon(Icons.arrow_back_rounded, color: textPrimary),
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).backButtonTooltip,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'Refer & Earn',
                    style: ArulTokens.screenTitle.copyWith(color: textPrimary),
                  ),
                ],
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
                  // Hero card.
                  Container(
                    padding: const EdgeInsets.fromLTRB(20, 26, 20, 20),
                    decoration: BoxDecoration(
                      gradient: heroGradient,
                      border: Border.all(color: heroBorder),
                      borderRadius: BorderRadius.circular(22),
                    ),
                    child: Column(
                      children: [
                        Container(
                          width: 56,
                          height: 56,
                          decoration: BoxDecoration(
                            color: ArulTokens.goldTintFill14,
                            shape: BoxShape.circle,
                          ),
                          alignment: Alignment.center,
                          child: Icon(
                            Icons.card_giftcard_rounded,
                            size: 28,
                            color: accent,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          'Gift a friend, earn a month',
                          textAlign: TextAlign.center,
                          style: ArulTokens.heroHeading.copyWith(
                            color: textPrimary,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          '30 days of free premium for every friend who '
                          'subscribes with your link',
                          textAlign: TextAlign.center,
                          style: ArulTokens.body.copyWith(color: heroSubText),
                        ),
                        const SizedBox(height: 16),
                        CtaButton(
                          label: 'Share via WhatsApp',
                          icon: Icons.share_rounded,
                          height: ArulTokens.ctaHeight50,
                          // TODO(phase-referral): build the referral link and
                          // hand it to the WhatsApp share intent.
                          onPressed: () {},
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: ArulTokens.contentGap),
                  // Rewards card.
                  Container(
                    padding: const EdgeInsets.all(ArulTokens.cardPadding16),
                    decoration: BoxDecoration(
                      color: cardBg,
                      border: Border.all(color: cardBorder),
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.emoji_events_rounded,
                          size: 26,
                          color: accent,
                        ),
                        const SizedBox(width: 14),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Rewards earned',
                              style: ArulTokens.rowSub.copyWith(
                                color: heroSubText,
                              ),
                            ),
                            Text(
                              '0 days',
                              style: ArulTokens.priceNumeral.copyWith(
                                fontSize: 22,
                                color: rewardValueColor,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: ArulTokens.contentGap),
                  // How it works card.
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: ArulTokens.cardPadding16,
                      vertical: 18,
                    ),
                    decoration: BoxDecoration(
                      color: cardBg,
                      border: Border.all(color: cardBorder),
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'How it works',
                          style: TextStyle(
                            fontSize: 14.5,
                            fontWeight: FontWeight.w600,
                            color: textPrimary,
                          ),
                        ),
                        const SizedBox(height: 14),
                        for (var i = 0; i < _steps.length; i++) ...[
                          if (i > 0) const SizedBox(height: 12),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                width: 24,
                                height: 24,
                                decoration: BoxDecoration(
                                  color: stepNumberBg,
                                  shape: BoxShape.circle,
                                ),
                                alignment: Alignment.center,
                                child: Text(
                                  _steps[i].n,
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w700,
                                    color: accent,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Padding(
                                  padding: const EdgeInsets.only(top: 3),
                                  child: Text(
                                    _steps[i].text,
                                    style: ArulTokens.body.copyWith(
                                      color: stepText,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                  // Empty state.
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 22,
                    ),
                    child: Column(
                      children: [
                        Icon(
                          Icons.group_rounded,
                          size: 26,
                          color: emptyIconColor,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'No referrals yet — your first friend is one '
                          'share away',
                          textAlign: TextAlign.center,
                          style: ArulTokens.body.copyWith(
                            fontSize: 13.5,
                            color: emptyTextColor,
                          ),
                        ),
                      ],
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
