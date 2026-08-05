import 'package:flutter/material.dart';

import '../../../app/l10n/app_localizations.dart';
import '../../../app/shell/app_shell.dart';
import '../../../app/widgets/cta_button.dart';
import '../../../app/widgets/gopuram_mark.dart';
import '../../../app/widgets/skeleton.dart';
import '../../../theme/arul_tokens.dart';
import 'ringtones_screen.dart';

/// Loading skeleton for the ringtone list: rows in the SAME geometry the real
/// list uses (46 cover at radius 13, one title bar, a 34 circle, a 32 pill in a
/// 44 box), built on the theme-following sliding-gradient [Skeleton] — the
/// app's one sanctioned loading pattern (no shimmer package, no ShaderMask;
/// docs/ui-direction.md).
///
/// Mirroring the geometry is the point: a skeleton whose rows are a different
/// height makes the whole list jump the moment the first page lands.
class RingtonesLoading extends StatelessWidget {
  const RingtonesLoading({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.fromLTRB(
        ArulTokens.screenPadding,
        0,
        ArulTokens.screenPadding,
        AppShell.dockClearance(context),
      ),
      itemCount: 7,
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
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: isDark ? ArulTokens.cardBgDark045 : ArulTokens.cardBgLight,
        borderRadius: BorderRadius.circular(ArulTokens.rowRadius),
        border: Border.all(
          color: isDark
              ? ArulTokens.cardBorderDark09
              : ArulTokens.cardBorderLight,
        ),
      ),
      child: const Row(
        children: [
          SizedBox.square(
            dimension: RingtoneRow.coverSize,
            child: Skeleton(
              borderRadius: BorderRadius.all(
                Radius.circular(ArulTokens.coverRadius),
              ),
            ),
          ),
          SizedBox(width: 12),
          Expanded(
            child: FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: 0.82,
              child: SizedBox(
                height: 14,
                child: Skeleton(
                  borderRadius: BorderRadius.all(Radius.circular(7)),
                ),
              ),
            ),
          ),
          SizedBox(width: 7),
          SizedBox.square(
            dimension: ArulTokens.minHitTarget,
            child: Center(
              child: SizedBox.square(
                dimension: 34,
                child: Skeleton(
                  borderRadius: BorderRadius.all(Radius.circular(17)),
                ),
              ),
            ),
          ),
          SizedBox(width: 7),
          SizedBox(
            width: 62,
            height: ArulTokens.minHitTarget,
            child: Center(
              child: SizedBox(
                height: 32,
                child: Skeleton(
                  borderRadius: BorderRadius.all(
                    Radius.circular(ArulTokens.pillRadius),
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

/// Designed empty state — ringtone content launches after wallpapers, so this
/// is a first-class "coming soon" surface, not an apology: the brand gopuram
/// over a quiet gold note, with devotional-register copy. Scrollable so
/// pull-to-refresh keeps working while empty, and inset at the bottom so the
/// composition centres in the space ABOVE the floating dock rather than behind
/// it.
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
            padding: EdgeInsets.only(
              left: 48,
              right: 48,
              bottom: AppShell.dockClearance(context),
            ),
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
/// Bottom-inset like [RingtonesEmpty] so the Retry button never sits under the
/// dock.
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
      padding: EdgeInsets.only(
        left: 48,
        right: 48,
        bottom: AppShell.dockClearance(context),
      ),
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
