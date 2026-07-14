import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/l10n/app_localizations.dart';
import '../../../app/widgets/cta_button.dart';
import '../../../app/widgets/gopuram_mark.dart';
import '../../../app/widgets/sliding_skeleton.dart';
import '../../../app/widgets/arul_chip.dart';
import '../../../data/models/wallpaper.dart';
import '../../../theme/arul_tokens.dart';
import '../providers/catalog_providers.dart';

/// The seven feed category labels, verbatim from the design (README > Reel
/// feed). The first is chrome; the rest come from the catalog. Title-cased at the
/// call site if the catalog ever yields a raw slug.
const _kAllLabel = 'All';

// ─────────────────────────────── Chips row ──────────────────────────────────

/// The horizontal category-chip row on the feed's solid top bar
/// (`pad 0 16px, gap 8, h-scroll`).
///
/// Sits on the themed frame, not over media, so the chips use
/// [ArulChipVariant.surface] and follow light/dark. The trailing padding is
/// wider than the leading one so the last chip can scroll fully clear of the
/// frame-colored continuation fade the feed paints over this row's right edge.
class FeedChips extends ConsumerWidget {
  const FeedChips({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final categories = ref.watch(categoriesProvider);
    final selected = ref.watch(selectedCategoryProvider);

    // No category names until the catalog lands; hold the row's height so the
    // media below does not jump.
    if (categories.isEmpty) return const SizedBox(height: 34);

    final items = <WallpaperCategory>[
      const WallpaperCategory(WallpaperCategory.allSlug, _kAllLabel),
      ...categories,
    ];

    return SizedBox(
      height: 34,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.only(
          left: ArulTokens.screenPadding,
          // Wider than the leading pad so the final chip can scroll clear of
          // the frame-colored "scrolls on" fade the feed paints over this edge.
          right: 28,
        ),
        itemCount: items.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final c = items[i];
          return Center(
            child: ArulChip(
              label: c.label,
              selected: c.slug == selected,
              variant: ArulChipVariant.surface,
              onTap: () =>
                  ref.read(selectedCategoryProvider.notifier).select(c.slug),
            ),
          );
        },
      ),
    );
  }
}

// ─────────────────────────────── Loading ────────────────────────────────────

/// Chip-row skeleton for the feed's top bar while the catalog loads: three
/// ivory-8% pills (README > Feed states > Loading). The chips themselves render
/// once categories land.
class FeedChipsSkeleton extends StatelessWidget {
  const FeedChipsSkeleton({super.key});

  static const _skeletonWidths = [64.0, 84.0, 92.0];

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fill = isDark
        ? ArulTokens.ivory.withValues(alpha: 0.08)
        : ArulTokens.maroonTintFill08;
    return SizedBox(
      height: 34,
      child: Row(
        children: [
          const SizedBox(width: ArulTokens.screenPadding),
          for (final w in _skeletonWidths) ...[
            Container(
              width: w,
              height: 32,
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

/// Feed loading fill (README > Feed states > Loading): the sliding-gradient
/// card with a centred gopuram + line that pulses on opacity only. No masked
/// shimmer, no spinner. Renders in the same inset rounded card as the reel so
/// the loading → content swap doesn't jump.
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
            Center(
              child: _OpacityPulse(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const GopuramMark(size: 38, color: ArulTokens.gold),
                    const SizedBox(height: 12),
                    Text(
                      'Bringing your wallpapers…',
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

/// Opacity pulse .55 ↔ 1 over 2s (README > Feed states > Loading). Transform/
/// opacity only.
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
    duration: const Duration(seconds: 2),
  )..repeat(reverse: true);

  late final Animation<double> _opacity = Tween<double>(
    begin: 0.55,
    end: 1,
  ).animate(CurvedAnimation(parent: _c, curve: Curves.easeInOut));

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      FadeTransition(opacity: _opacity, child: widget.child);
}

// ──────────────────────────────── Empty ─────────────────────────────────────

/// Empty state for a category with no wallpapers (README > Feed states > Empty).
/// Chips remain (so the user can jump elsewhere); a gentle gopuram + copy + an
/// outlined gold "Browse all" that switches the category back to All.
class FeedEmpty extends StatelessWidget {
  const FeedEmpty({
    super.key,
    required this.categoryLabel,
    required this.onBrowseAll,
  });

  final String categoryLabel;
  final VoidCallback onBrowseAll;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // Chips stay visible via the feed's persistent top bar; this is only the
    // body, rendered on the themed frame.
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
            'Nothing here yet',
            textAlign: TextAlign.center,
            style: ArulTokens.screenTitle.copyWith(
              fontSize: 20,
              color: isDark ? ArulTokens.ivory : ArulTokens.lightText,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'New $categoryLabel wallpapers arrive often. '
            'Meanwhile, explore everything.',
            textAlign: TextAlign.center,
            style: ArulTokens.body.copyWith(
              color: isDark ? ArulTokens.darkMuted : ArulTokens.lightBody,
            ),
          ),
          const SizedBox(height: 20),
          _OutlinedAccentPill(label: 'Browse all', onTap: onBrowseAll),
        ],
      ),
    );
  }
}

/// Outlined accent pill (README > Feed states > Empty: `border gold-50%, gold
/// text, pad 12 26, r999`) — gold on the dark frame, maroon on the light one.
class _OutlinedAccentPill extends StatelessWidget {
  const _OutlinedAccentPill({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(ArulTokens.pillRadius),
          border: Border.all(
            color: isDark
                ? ArulTokens.goldBorder50
                : ArulTokens.maroon.withValues(alpha: 0.5),
          ),
        ),
        child: Text(
          label,
          style: ArulTokens.button.copyWith(
            fontSize: 14,
            color: isDark ? ArulTokens.gold : ArulTokens.maroon,
          ),
        ),
      ),
    );
  }
}

// ──────────────────────────────── Error ─────────────────────────────────────

/// Full-screen feed error (README > Feed states > Error). `cloud_off`, plain
/// words, one green Retry.
///
/// Two modes, same layout/tokens:
///   - default ([offline] false): the catalog fetch failed AND there is no
///     cached copy — "Couldn't load wallpapers" / "Check your connection…".
///   - [offline] true: the device is offline, so the feed is gated shut
///     regardless of cache — "No internet" / "Turn on the internet to see
///     wallpapers." (the product's "boom, no wallpapers" state).
class FeedError extends StatelessWidget {
  const FeedError({super.key, required this.onRetry, this.offline = false});

  final VoidCallback onRetry;

  /// Selects the offline copy over the generic load-failure copy. Nothing else
  /// changes — same icon, same green Retry, same layout.
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
            height: 46,
            fontSize: 14,
            expand: false,
          ),
        ],
      ),
    );
  }
}
