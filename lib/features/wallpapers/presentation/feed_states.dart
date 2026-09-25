import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/l10n/app_localizations.dart';
import '../../../app/widgets/cta_button.dart';
import '../../../app/widgets/gopuram_mark.dart';
import '../../../app/widgets/sliding_skeleton.dart';
import '../../../app/widgets/arul_chip.dart';
import '../../../core/haptics/arul_haptics.dart';
import '../../../data/models/wallpaper.dart';
import '../../../theme/arul_tokens.dart';
import '../providers/catalog_providers.dart';
import '../../../app/theme/motion.dart';
import 'feed_card_geometry.dart';

/// The horizontal category-chip row on the feed's solid top bar.
///
/// Sits on the themed frame, not over media -> the chips follow light/dark.
/// [ArulChipVariant.category] — the SAME variant the ringtone browse row uses.
/// Both rows are the one browse axis (CLAUDE.md §5b) doing one job.
/// Different variants made the two tabs disagree on height, inactive fill and label weight.
/// The chip is the same control; it gets the same clothes.
class FeedChips extends ConsumerWidget {
  const FeedChips({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final categories = ref.watch(categoriesProvider);
    final selected = ref.watch(selectedCategoryProvider);
    final showNew = ref.watch(showNewCategoryProvider);

    // A loaded catalog with NO categories -> collapse, never a 34px band of nothing under the title.
    // The loading case never reaches here — FeedChipsSkeleton holds the height, so nothing jumps.
    if (categories.isEmpty) return const SizedBox.shrink();

    // All, then New, then the catalog's own chips. Both leaders are CHROME built here, which is why
    // neither can reach `categoriesProvider` — and so neither can reach the Upload picker, which
    // reads that provider to decide what a user may submit into. A window is not a submittable
    // category. `orderedByCms` sorts only what came off the catalog, so an operator's drag can
    // never move these two either.
    final items = <WallpaperCategory>[
      // The same ARB key the ringtone row reads -> the two tabs can never disagree on this word.
      WallpaperCategory(WallpaperCategory.allSlug, l10n.categoryAll),
      // Both chrome chips speak the user's language (owner's call, once All was translated); the
      // catalog's deity slugs stay as the catalog spells them.
      if (showNew)
        WallpaperCategory(WallpaperCategory.newSlug, l10n.categoryNew),
      ...categories,
    ];

    return SizedBox(
      // The chips draw 34 and are tapped at [ArulTokens.minHitTarget] -> the strip owes the taller
      // box or the hit area it gains is clipped straight back off. The row still sits in equal air.
      height: ArulChip.categoryStripHeight,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(
          horizontal: ArulTokens.screenPadding,
        ),
        itemCount: items.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final c = items[i];
          return ArulChip(
            label: c.label,
            selected: c.slug == selected,
            variant: ArulChipVariant.category,
            identifier: 'arul_chip_${c.slug}',
            onTap: () =>
                ref.read(selectedCategoryProvider.notifier).select(c.slug),
          );
        },
      ),
    );
  }
}

class FeedChipsSkeleton extends StatelessWidget {
  const FeedChipsSkeleton({super.key});

  static const _skeletonWidths = [64.0, 84.0, 92.0];

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fill = isDark
        ? ArulTokens.cardBgDark045
        : ArulTokens.maroonTintFill08;
    return SizedBox(
      // Matches the real chip row it stands in for -> the strip must not resize when they land.
      height: ArulChip.categoryStripHeight,
      child: Row(
        children: [
          const SizedBox(width: ArulTokens.screenPadding),
          for (final w in _skeletonWidths) ...[
            Container(
              width: w,
              height: ArulChip.categoryHeight,
              decoration: BoxDecoration(
                color: fill,
                borderRadius: BorderRadius.circular(ArulTokens.pillRadius),
              ),
            ),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }
}

/// Feed loading fill — the sliding-gradient card with a centred gopuram that pulses on opacity only.
/// NO masked shimmer, no spinner.
/// Renders in the same inset rounded card as the reel -> the loading → content swap never jumps.
class FeedLoading extends StatelessWidget {
  const FeedLoading({super.key, required this.margin, required this.radius});

  final EdgeInsets margin;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: margin,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: Stack(
          fit: StackFit.expand,
          children: [
            const SlidingSkeleton(),

            // The card's OWN chrome, not the wallpaper's -> the scrim and the Apply/Share row sit in
            // the same place on EVERY card regardless of what lands, so they belong in the skeleton
            // (W9). The live mark does NOT join them: it is conditional on `wallpaper.kind`, data the
            // loading state does not have yet -> a guess would pop a glyph OFF a static card (most of
            // the catalog) rather than prevent a pop, which is worse than showing nothing.
            const Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: FeedCardGeometry.scrimHeight,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: ArulTokens.feedBottomScrim,
                  ),
                ),
              ),
            ),
            const Positioned(
              left: FeedCardGeometry.actionInset,
              right: FeedCardGeometry.actionInset,
              bottom: FeedCardGeometry.actionInset,
              child: IgnorePointer(child: _ActionBarSkeleton()),
            ),

            Center(
              child: _OpacityPulse(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const GopuramMark(size: 38, color: ArulTokens.gold),
                    const SizedBox(height: 12),
                    Text(
                      AppLocalizations.of(context).feedLoadingBody,
                      style: ArulTokens.body.copyWith(
                        color: ArulTokens.darkTextSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Stand-in for the card's Apply pill + Share circle (`_ActionBar` in feed_screen.dart) -> both sit
/// on EVERY card regardless of content, unlike the live mark, so they belong here (see [FeedLoading]).
///
/// Every number comes from [FeedCardGeometry], the SAME source `_ActionBar`/`_ApplyPill`/
/// `_ShareCircle` read -> the skeleton cannot drift out of step with the row it stands in for, which
/// is the whole point of a content-shaped skeleton. The pill uses the FLOOR width, so real content
/// can only grow into this placeholder, never shrink out of it.
class _ActionBarSkeleton extends StatelessWidget {
  const _ActionBarSkeleton();

  static const double _barHeight = FeedCardGeometry.actionBarHeight;
  static const double _pillFloorWidth = FeedCardGeometry.applyPillMinWidth;
  static const double _shareDiameter = FeedCardGeometry.shareDiameter;
  static const double _gap = FeedCardGeometry.actionGap;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        SizedBox(
          width: _pillFloorWidth,
          height: _barHeight,
          child: SlidingSkeleton(
            borderRadius: BorderRadius.circular(ArulTokens.pillRadius),
          ),
        ),
        const SizedBox(width: _gap),
        SizedBox.square(
          dimension: _shareDiameter,
          child: SlidingSkeleton(
            borderRadius: BorderRadius.circular(_shareDiameter / 2),
          ),
        ),
      ],
    );
  }
}

class _OpacityPulse extends StatefulWidget {
  const _OpacityPulse({required this.child});

  final Widget child;

  @override
  State<_OpacityPulse> createState() => _OpacityPulseState();
}

class _OpacityPulseState extends State<_OpacityPulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: Motion.loadingPulse,
  );

  /// Armed from [didChangeDependencies] — `reduceMotion` needs an InheritedWidget lookup.
  bool _motionStarted = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_motionStarted) return;
    _motionStarted = true;
    if (context.reduceMotion) {
      // Parked at full opacity, the bright end of the pulse — the resting state, never the dim one.
      _c.value = 1;
    } else {
      _c.repeat(reverse: true);
    }
  }

  late final Animation<double> _opacity = Tween<double>(
    begin: 0.55,
    end: 1,
  ).animate(CurvedAnimation(parent: _c, curve: Motion.swayCurve));

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      FadeTransition(opacity: _opacity, child: widget.child);
}

class FeedEmpty extends StatelessWidget {
  const FeedEmpty({super.key, required this.onBrowseAll});

  final VoidCallback onBrowseAll;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // The chips stay visible via the feed's persistent top bar — this is only the body.
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 48),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Opacity(
            opacity: 0.55,
            child: GopuramMark(
              size: 40,
              color: isDark ? ArulTokens.gold : ArulTokens.maroon,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            l10n.feedEmptyTitle,
            textAlign: TextAlign.center,
            style: ArulTokens.screenTitle.copyWith(
              fontSize: 20,
              color: isDark ? ArulTokens.ivory : ArulTokens.lightText,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            l10n.feedEmptyBody,
            textAlign: TextAlign.center,
            style: ArulTokens.body.copyWith(
              color: isDark ? ArulTokens.darkMuted : ArulTokens.lightBody,
            ),
          ),
          const SizedBox(height: 20),
          Semantics(
            container: true,
            identifier: 'arul_feed_browse_all',
            child: _OutlinedAccentPill(
              label: l10n.feedBrowseAll,
              onTap: onBrowseAll,
            ),
          ),
        ],
      ),
    );
  }
}

/// Outlined accent pill — `border gold-50%, pad 12 26, r999`; gold on dark, maroon on light.
///
/// Answers the finger like every other button: a tap haptic on press-DOWN, a tint while pressed,
/// and a [ArulTokens.minHitTarget] hit box around the drawn pill.
class _OutlinedAccentPill extends StatefulWidget {
  const _OutlinedAccentPill({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  State<_OutlinedAccentPill> createState() => _OutlinedAccentPillState();
}

class _OutlinedAccentPillState extends State<_OutlinedAccentPill> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = isDark ? ArulTokens.gold : ArulTokens.maroon;
    return Semantics(
      button: true,
      label: widget.label,
      child: GestureDetector(
        onTapDown: (_) {
          ArulHaptics.tap();
          setState(() => _pressed = true);
        },
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          height: ArulTokens.minHitTarget,
          child: Center(
            widthFactor: 1,
            child: AnimatedContainer(
              duration: context.reduceMotion ? Duration.zero : Motion.quick,
              curve: Motion.quickCurve,
              padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 12),
              decoration: BoxDecoration(
                // The press tints the pill with its own accent -> feedback in the pill's colour,
                // never a foreign ripple on the ivory ground.
                color: _pressed
                    ? accent.withValues(alpha: 0.12)
                    : accent.withValues(alpha: 0),
                borderRadius: BorderRadius.circular(ArulTokens.pillRadius),
                border: Border.all(
                  color: isDark
                      ? ArulTokens.goldBorder50
                      : ArulTokens.maroon.withValues(alpha: 0.5),
                ),
              ),
              child: Text(
                widget.label,
                style: ArulTokens.button.copyWith(fontSize: 14, color: accent),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Full-screen feed error — `cloud_off`, plain words, one green Retry.
///
/// Two modes, same layout and tokens:
///   - [offline] false — the catalog fetch failed AND there is no cached copy;
///   - [offline] true — the device is offline, so the feed is gated shut regardless of cache.
class FeedError extends StatelessWidget {
  const FeedError({super.key, required this.onRetry, this.offline = false});

  final VoidCallback onRetry;

  final bool offline;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final title = offline ? l10n.offlineTitle : l10n.feedErrorTitle;
    final body = offline ? l10n.offlineFeedBody : l10n.feedErrorBody;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 48),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.cloud_off_rounded,
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
            identifier: 'arul_feed_retry',
            height: ArulTokens.minHitTarget,
            fontSize: 14,
            expand: false,
          ),
        ],
      ),
    );
  }
}
