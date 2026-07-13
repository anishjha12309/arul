import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/l10n/app_localizations.dart';
import '../../../app/theme/tokens.dart';
import '../../../data/models/wallpaper.dart';
import '../providers/catalog_providers.dart';

/// The browse axis: category, never static-vs-live. Type is a rendering detail
/// the user should not have to think about, so live and static interleave inside
/// every category.
///
/// A scrolling row of chips on a REAL surface, not scrim-defended pills floating
/// over a wallpaper. That change is what lets the six languages work: Tamil,
/// Telugu, Kannada and Malayalam category names are materially longer than the
/// English ones, and ordinary text layout on a solid ground handles that, where
/// hand-tuned pill padding over arbitrary imagery does not.
class CategoryTabs extends ConsumerWidget implements PreferredSizeWidget {
  const CategoryTabs({super.key});

  @override
  Size get preferredSize => const Size.fromHeight(52);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final categories = ref.watch(categoriesProvider);
    final selected = ref.watch(selectedCategoryProvider);

    // Until the catalog lands there are no category names to render. Hold the
    // row's height so the grid below does not jump when they arrive.
    if (categories.isEmpty) return const SizedBox(height: 52);

    final items = <WallpaperCategory>[
      WallpaperCategory(WallpaperCategory.allSlug, l10n.categoryAll),
      ...categories,
    ];

    return SizedBox(
      height: 52,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: Gap.md),
        itemCount: items.length,
        separatorBuilder: (_, _) => const SizedBox(width: Gap.sm),
        itemBuilder: (context, i) {
          final c = items[i];
          return _CategoryChip(
            label: c.label,
            selected: c.slug == selected,
            onTap: () =>
                ref.read(selectedCategoryProvider.notifier).select(c.slug),
          );
        },
      ),
    );
  }
}

class _CategoryChip extends StatelessWidget {
  const _CategoryChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Center(
      child: Material(
        color: selected ? scheme.primary : scheme.surfaceContainerHighest,
        borderRadius: const BorderRadius.all(Radius.circular(999)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Gap.md,
              vertical: Gap.sm,
            ),
            child: Text(
              label,
              style: theme.textTheme.labelLarge?.copyWith(
                color: selected ? scheme.onPrimary : scheme.onSurfaceVariant,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
