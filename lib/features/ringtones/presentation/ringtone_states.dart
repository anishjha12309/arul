import 'package:flutter/material.dart';

import '../../../app/l10n/app_localizations.dart';
import '../../../app/widgets/cta_button.dart';
import '../../../app/widgets/gopuram_mark.dart';
import '../../../app/widgets/skeleton.dart';
import '../../../theme/arul_tokens.dart';

/// Loading skeleton for the ringtone list: card-shaped rows (cover square +
/// two text bars + a pill) built on the theme-following sliding-gradient
/// [Skeleton] — the app's one sanctioned loading pattern (no shimmer package,
/// no ShaderMask; docs/ui-direction.md).
class RingtonesLoading extends StatelessWidget {
  const RingtonesLoading({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(
        ArulTokens.screenPadding,
        14,
        ArulTokens.screenPadding,
        14,
      ),
      itemCount: 6,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (_, _) => const _SkeletonRow(),
    );
  }
}

class _SkeletonRow extends StatelessWidget {
  const _SkeletonRow();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark ? ArulTokens.cardBgDark04 : ArulTokens.cardBgLight,
        borderRadius: BorderRadius.circular(ArulTokens.cardRadius),
        border: Border.all(
          color: isDark
              ? ArulTokens.cardBorderDark09
              : ArulTokens.cardBorderLight,
        ),
      ),
      child: Row(
        children: [
          const SizedBox(
            width: 56,
            height: 56,
            child: Skeleton(
              borderRadius: BorderRadius.all(Radius.circular(12)),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                SizedBox(
                  width: double.infinity,
                  height: 14,
                  child: Skeleton(
                    borderRadius: BorderRadius.all(Radius.circular(7)),
                  ),
                ),
                SizedBox(height: 8),
                FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: 0.4,
                  child: SizedBox(
                    height: 11,
                    child: Skeleton(
                      borderRadius: BorderRadius.all(Radius.circular(5.5)),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          const SizedBox(
            width: 64,
            height: 32,
            child: Skeleton(
              borderRadius: BorderRadius.all(
                Radius.circular(ArulTokens.pillRadius),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Designed empty state — ringtone content launches after wallpapers, so this
/// is a first-class "coming soon" surface, not an apology: the brand gopuram
/// over a quiet gold note, with devotional-register copy. Scrollable so
/// pull-to-refresh keeps working while empty.
class RingtonesEmpty extends StatelessWidget {
  const RingtonesEmpty({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = isDark ? ArulTokens.gold : ArulTokens.maroon;

    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: SizedBox(
          height: constraints.maxHeight,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 48),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // The motif: the brand gopuram flanked by fading hairlines,
                // with a small gold note beneath — same quiet language as the
                // feed's end-of-reel mark.
                Opacity(
                  opacity: 0.6,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _hairline(accent, leading: true),
                      const SizedBox(width: 12),
                      GopuramMark(size: 40, color: accent),
                      const SizedBox(width: 12),
                      _hairline(accent, leading: false),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Icon(
                  Icons.music_note_outlined,
                  size: 20,
                  color: accent.withValues(alpha: 0.55),
                ),
                const SizedBox(height: 14),
                Text(
                  l10n.ringtonesEmptyTitle,
                  textAlign: TextAlign.center,
                  style: ArulTokens.screenTitle.copyWith(
                    fontSize: 20,
                    color: isDark ? ArulTokens.ivory : ArulTokens.lightText,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  l10n.ringtonesEmptyBody,
                  textAlign: TextAlign.center,
                  style: ArulTokens.body.copyWith(
                    color: isDark ? ArulTokens.darkMuted : ArulTokens.lightBody,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _hairline(Color accent, {required bool leading}) => Container(
    width: 30,
    height: 1,
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: leading ? Alignment.centerLeft : Alignment.centerRight,
        end: leading ? Alignment.centerRight : Alignment.centerLeft,
        colors: [accent.withValues(alpha: 0), accent.withValues(alpha: 0.4)],
      ),
    ),
  );
}

/// Full-body ringtone error state — same layout/tokens as the feed's
/// [FeedError], with ringtone copy. [offline] selects the no-internet copy.
class RingtonesError extends StatelessWidget {
  const RingtonesError({
    super.key,
    required this.onRetry,
    this.offline = false,
  });

  final VoidCallback onRetry;
  final bool offline;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final title = offline ? l10n.offlineTitle : l10n.ringtonesErrorTitle;
    final body = offline ? l10n.offlineBody : l10n.feedErrorBody;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 48),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            offline ? Icons.cloud_off_rounded : Icons.music_off_rounded,
            size: 34,
            color: (isDark ? ArulTokens.ivory : ArulTokens.lightText)
                .withValues(alpha: 0.35),
          ),
          const SizedBox(height: 12),
          Text(
            title,
            textAlign: TextAlign.center,
            style: ArulTokens.screenTitle.copyWith(
              fontSize: 20,
              color: isDark ? ArulTokens.ivory : ArulTokens.lightText,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            body,
            textAlign: TextAlign.center,
            style: ArulTokens.body.copyWith(
              color: isDark ? ArulTokens.darkMuted : ArulTokens.lightBody,
            ),
          ),
          const SizedBox(height: 20),
          CtaButton(
            label: l10n.retry,
            icon: Icons.refresh_rounded,
            onPressed: onRetry,
            height: 46,
            fontSize: 14,
            expand: false,
          ),
        ],
      ),
    );
  }
}
