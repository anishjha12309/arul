import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app/widgets/arul_sheet.dart';
import '../../../app/widgets/cta_button.dart';
import '../../../app/widgets/gopuram_mark.dart';
import '../../../theme/arul_tokens.dart';

/// The premium bottom sheet shown on the SECOND gated tap in a session
/// (README > Premium gate). A soft nudge toward the full premium SCREEN — not
/// the screen itself (that is `/premium`, owned elsewhere).
///
/// Gradient `#241014 → #1A0B0F`, gold-40% top hairline (both from [ArulSheet]'s
/// `gradient` variant); gopuram 30px + "Arul Premium" Marcellus 22px + one-line
/// pitch; a plan row; the green "Start free trial" CTA (→ `/premium?source=`);
/// and a quiet "Keep browsing free" that dismisses.
class PremiumSheet {
  const PremiumSheet._();

  /// Copy is hardcoded verbatim for this design pass (README > Premium gate).
  static const _pitch =
      'Every wallpaper, live and still. Apply and share freely '
      'across all six categories.';

  static Future<void> show(BuildContext context, {required String source}) {
    return showArulSheet<void>(
      context,
      // Gradient top is a dark-only flourish; ArulSheet falls back to the flat
      // light surface when the app theme is light.
      gradient: true,
      builder: (_) => _PremiumSheetBody(source: source),
    );
  }
}

class _PremiumSheetBody extends StatelessWidget {
  const _PremiumSheetBody({required this.source});

  /// The blocked verb (`apply` / `share`) that opened this sheet; forwarded to
  /// the premium screen for analytics.
  final String source;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final titleColor = isDark ? ArulTokens.darkText : ArulTokens.lightText;
    final pitchColor = isDark ? ArulTokens.darkBodyWarm : ArulTokens.lightBody;
    final subColor = isDark
        ? ArulTokens.darkTextSecondary
        : ArulTokens.lightSecondary;

    return Padding(
      // The grabber (and its 10px vertical padding) is supplied by ArulSheet;
      // here only the sheet body inset (README: pad 20 22 26).
      padding: const EdgeInsets.fromLTRB(22, 6, 22, 26),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Column(
            children: [
              const GopuramMark(size: 30, color: ArulTokens.gold),
              const SizedBox(height: 6),
              Text(
                'Arul Premium',
                style: ArulTokens.screenTitle.copyWith(
                  fontSize: 22,
                  color: titleColor,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                PremiumSheet._pitch,
                textAlign: TextAlign.center,
                style: ArulTokens.body.copyWith(color: pitchColor),
              ),
            ],
          ),
          const SizedBox(height: 14),

          // Plan row.
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(ArulTokens.cardRadius - 4),
              border: Border.all(color: ArulTokens.goldBorder40),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '₹199 / month',
                        style: ArulTokens.rowTitle.copyWith(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: titleColor,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'UPI Autopay · cancel anytime',
                        style: ArulTokens.rowSub.copyWith(color: subColor),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: ArulTokens.gold,
                    borderRadius: BorderRadius.circular(ArulTokens.pillRadius),
                  ),
                  // Must match TRIAL_DAYS in workers/src/routes/payments.ts.
                  child: Text(
                    '1 DAY FREE',
                    style: ArulTokens.caption.copyWith(
                      fontWeight: FontWeight.w700,
                      color: ArulTokens.darkSurface,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),

          CtaButton(
            label: 'Start free trial',
            height: ArulTokens.ctaHeight52,
            fontSize: 16,
            onPressed: () {
              Navigator.of(context).pop();
              context.push('/premium?source=$source');
            },
          ),
          const SizedBox(height: 14),

          GestureDetector(
            onTap: () => Navigator.of(context).pop(),
            behavior: HitTestBehavior.opaque,
            child: Text(
              'Keep browsing free',
              textAlign: TextAlign.center,
              style: ArulTokens.body.copyWith(color: subColor),
            ),
          ),
        ],
      ),
    );
  }
}
