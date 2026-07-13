import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/l10n/app_localizations.dart';
import '../../../app/theme/tokens.dart';
import '../../../app/widgets/skeleton.dart';
import '../../../app/widgets/state_views.dart';
import '../../../data/models/wallpaper.dart';
import '../providers/catalog_providers.dart';
import 'apply_restore.dart';
import 'category_tabs.dart';
import 'viewer_screen.dart';
import 'wallpaper_tile.dart';

/// Home. A real browse surface: app bar, category tabs, a grid of wallpapers.
///
/// This is deliberately NOT the immersive pager. The pager is an
/// ambient-consumption shape (Shorts, Reels) — right when there is no target
/// item. Arul is a picker: the user arrives wanting *a* Murugan wallpaper and
/// needs to compare across ~50 of them, which a one-at-a-time pager is a bad tool
/// for. The pager still exists — it is the viewer you tap into.
///
/// It is also the cheaper idle state on the hardware we target: a grid tile is a
/// still image, so the video decoder stays completely idle until the user
/// deliberately opens something.
class BrowseScreen extends ConsumerStatefulWidget {
  const BrowseScreen({super.key});

  @override
  ConsumerState<BrowseScreen> createState() => _BrowseScreenState();
}

class _BrowseScreenState extends ConsumerState<BrowseScreen> with ApplyRestore {
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final feed = ref.watch(feedProvider);

    // If a wallpaper apply took the app away and it came back cold (Android 12+
    // recreates the Activity on a wallpaper change), put the user back on the
    // wallpaper they were setting instead of at the top of the grid.
    if (ref.watch(catalogProvider) case AsyncData(:final value)) {
      maybeRestoreAfterApply(value);
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.appName),
        actions: [
          IconButton(
            onPressed: () => context.push('/premium?source=browse'),
            icon: const Icon(Icons.workspace_premium_outlined),
            tooltip: l10n.premiumTitle,
          ),
          IconButton(
            onPressed: () => context.push('/settings'),
            icon: const Icon(Icons.settings_outlined),
            tooltip: l10n.settingsTitle,
          ),
          const SizedBox(width: Gap.xs),
        ],
        bottom: const CategoryTabs(),
      ),
      body: switch (feed) {
        // Skeleton tiles in the real grid geometry, so nothing reflows when the
        // data lands — the page does not jump under the user's thumb.
        AsyncLoading() => const _Grid.loading(),

        AsyncData(:final value) when value.isEmpty => StateView.empty(
          title: l10n.feedEmptyTitle,
          message: l10n.feedEmptyBody,
        ),

        AsyncData(:final value) => _Grid(items: value),

        // A failed catalog fetch is the only true full-screen error: without it
        // there is nothing to show. A single broken IMAGE is not this — that
        // degrades to one muted tile (see WallpaperTile).
        AsyncError() => StateView.error(
          title: l10n.feedErrorTitle,
          message: l10n.feedErrorBody,
          actionLabel: l10n.retry,
          onAction: () => ref.invalidate(catalogProvider),
        ),
      },
    );
  }
}

class _Grid extends StatelessWidget {
  const _Grid({required this.items}) : loading = false;
  const _Grid.loading() : items = const [], loading = true;

  final List<Wallpaper> items;
  final bool loading;

  /// Enough skeletons to fill any phone above the fold; the real count arrives
  /// milliseconds later.
  static const _skeletonCount = 8;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: EdgeInsets.fromLTRB(
        Gap.md,
        Gap.md,
        Gap.md,
        // Clear the gesture bar: a tile under the navigation inset is a tile the
        // user cannot tap.
        MediaQuery.viewPaddingOf(context).bottom + Gap.md,
      ),
      // maxCrossAxisExtent, not a hardcoded crossAxisCount: phones land on 2
      // columns at any normal width, and a foldable or tablet gets 3 for free
      // instead of two absurdly wide tiles.
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 200,
        mainAxisSpacing: Gap.sm,
        crossAxisSpacing: Gap.sm,
        // The catalog is uniformly 9:16, so the tile matches it exactly: no
        // letterboxing, no crop guessing, and no reason for masonry (which
        // exists to reconcile MIXED aspect ratios — a problem this content
        // does not have).
        childAspectRatio: 9 / 16,
      ),
      itemCount: loading ? _skeletonCount : items.length,
      itemBuilder: (context, i) {
        if (loading) {
          return const Skeleton(borderRadius: WallpaperTile.radius);
        }
        final w = items[i];
        return WallpaperTile(
          key: ValueKey(w.id),
          wallpaper: w,
          // The viewer opens on the CURRENTLY FILTERED list, so the category the
          // user was browsing carries through the tap: swiping in the viewer moves
          // through the same wallpapers they were just looking at, not the whole
          // 428-item catalog.
          onTap: () => Navigator.of(
            context,
          ).push(ViewerScreen.route(items: items, initialIndex: i)),
        );
      },
    );
  }
}
