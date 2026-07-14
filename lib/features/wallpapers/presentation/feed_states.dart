import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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

/// The horizontal category-chip row that floats on the feed's top scrim
/// (README > Reel feed: `top:14px, pad 0 16px, gap 8, h-scroll`).
///
/// A bare scrollable [Row]; the caller positions it (top = safe-area + 14) and,
/// in the reel, wraps it in the chrome-recede opacity. Rendered over media, so
/// the chips use [ArulChipVariant.feed] (fixed dark palette, gold when active).
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
        padding: const EdgeInsets.symmetric(
          horizontal: ArulTokens.screenPadding,
        ),
        itemCount: items.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final c = items[i];
          return Center(
            child: ArulChip(
              label: c.label,
              selected: c.slug == selected,
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

/// Full-bleed feed loading (README > Feed states > Loading): a sliding-gradient
/// fill, three ivory-8% chip skeletons, and a centred gopuram + line that pulses
/// on opacity only. No masked shimmer, no spinner.
class FeedLoading extends StatelessWidget {
  const FeedLoading({super.key});

  static const _skeletonWidths = [64.0, 84.0, 92.0];

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.viewPaddingOf(context).top;

    return Stack(
      fit: StackFit.expand,
      children: [
        const SlidingSkeleton(),

        Positioned(
          top: topInset + 14,
          left: ArulTokens.screenPadding,
          right: ArulTokens.screenPadding,
          child: Row(
            children: [
              for (final w in _skeletonWidths) ...[
                Container(
                  width: w,
                  height: 32,
                  decoration: BoxDecoration(
                    color: ArulTokens.ivory.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(ArulTokens.pillRadius),
                  ),
                ),
                const SizedBox(width: 8),
              ],
            ],
          ),
        ),

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
    final topInset = MediaQuery.viewPaddingOf(context).top;

    return Stack(
      fit: StackFit.expand,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 48),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Opacity(
                opacity: 0.55,
                child: const GopuramMark(size: 40, color: ArulTokens.gold),
              ),
              const SizedBox(height: 12),
              Text(
                'Nothing here yet',
                textAlign: TextAlign.center,
                style: ArulTokens.screenTitle.copyWith(
                  fontSize: 20,
                  color: ArulTokens.ivory,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'New $categoryLabel wallpapers arrive often. '
                'Meanwhile, explore everything.',
                textAlign: TextAlign.center,
                style: ArulTokens.body.copyWith(color: ArulTokens.darkMuted),
              ),
              const SizedBox(height: 20),
              _OutlinedGoldPill(label: 'Browse all', onTap: onBrowseAll),
            ],
          ),
        ),

        Positioned(
          top: topInset + 14,
          left: 0,
          right: 0,
          child: const FeedChips(),
        ),
      ],
    );
  }
}

/// Outlined gold pill (README > Feed states > Empty: `border gold-50%, gold
/// text, pad 12 26, r999`).
class _OutlinedGoldPill extends StatelessWidget {
  const _OutlinedGoldPill({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(ArulTokens.pillRadius),
          border: Border.all(color: ArulTokens.goldBorder50),
        ),
        child: Text(
          label,
          style: ArulTokens.button.copyWith(
            fontSize: 14,
            color: ArulTokens.gold,
          ),
        ),
      ),
    );
  }
}

// ──────────────────────────────── Error ─────────────────────────────────────

/// Full-screen feed error — only when the catalog fetch fails AND there is no
/// cached copy (README > Feed states > Error). `cloud_off`, plain words, one
/// green Retry.
class FeedError extends StatelessWidget {
  const FeedError({super.key, required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 48),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.cloud_off_rounded,
            size: 34,
            color: ArulTokens.ivory.withValues(alpha: 0.35),
          ),
          const SizedBox(height: 12),
          Text(
            "Couldn't load wallpapers",
            textAlign: TextAlign.center,
            style: ArulTokens.screenTitle.copyWith(
              fontSize: 20,
              color: ArulTokens.ivory,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Check your connection and try again.',
            textAlign: TextAlign.center,
            style: ArulTokens.body.copyWith(color: ArulTokens.darkMuted),
          ),
          const SizedBox(height: 20),
          CtaButton(
            label: 'Retry',
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
