import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/widgets/reel/reel_prefetch_service.dart';
import '../../../app/widgets/reel/video_preload_controller.dart';
import '../../../core/config/app_config.dart';
import '../../../data/models/catalog_page.dart';
import '../../../data/models/wallpaper.dart';
import '../../../data/repositories/repository_providers.dart';
import '../../auth/providers/auth_providers.dart';
import '../../wallpapers/providers/catalog_providers.dart';
import '../data/status_media_service.dart';
import '../data/status_prefetch_service.dart';
import '../domain/status_video.dart';

final statusPrefetchServiceProvider =
    Provider<ReelPrefetchService<StatusVideo>>((ref) {
      final service = StatusPrefetchService(cdnBaseUrl: AppConfig.cdnBaseUrl);
      ref.onDispose(service.dispose);
      return service;
    });

/// The status reel's own pool: current + next only, audible, hidden until the shell shows it.
/// App-scoped for the same reason as the feed's -> `ref` is unusable from a screen's dispose().
final statusVideoControllerProvider =
    Provider<VideoPreloadController<StatusVideo>>((ref) {
      final controller = VideoPreloadController<StatusVideo>(
        cdnBaseUrl: AppConfig.cdnBaseUrl,
        prefetch: ref.read(statusPrefetchServiceProvider),
        keepBehind: 0,
        audio: true,
        visible: false,
      );
      ref.onDispose(controller.dispose);
      return controller;
    });

final statusMediaServiceProvider = Provider<StatusMediaService>(
  (ref) => ApiStatusMediaService(apiClient: ref.watch(apiClientProvider)),
);

/// The status catalog, drained from the CDN on the first watch — only the Status screen watches it,
/// so a phone that never opens the tab never fetches a byte of it.
final statusCatalogProvider =
    AsyncNotifierProvider<StatusCatalogNotifier, List<StatusVideo>>(
      StatusCatalogNotifier.new,
    );

class StatusCatalogNotifier extends AsyncNotifier<List<StatusVideo>> {
  @override
  Future<List<StatusVideo>> build() => _fetch();

  /// Retry from the error card -> re-reads the version pointer so a fresh publish lands.
  Future<void> refresh() async {
    invalidateCatalogVersion();
    state = const AsyncLoading();
    state = await AsyncValue.guard(_fetch);
  }

  Future<List<StatusVideo>> _fetch() async {
    final client = ref.read(catalogHttpClientProvider);

    Future<CatalogPage<StatusVideo>?> fetch(int page) => client.fetchPage(
      scope: 'statuses',
      slug: 'all',
      page: page,
      itemFromJson: StatusVideo.fromJson,
    );

    final first = await fetch(1);
    if (first == null) {
      // Every status publish writes page 1, so its absence is an operational fault, not an empty tab.
      throw StateError('status catalog page 1 missing on CDN');
    }
    final all = [...first.items];
    for (var page = 2; first.hasMore && page <= first.totalPages; page++) {
      final next = await fetch(page);
      if (next == null) break;
      all.addAll(next.items);
    }
    return List<StatusVideo>.unmodifiable(all);
  }
}

/// Chips derived from the catalog, ordered by the CMS's `category_order.statuses` when set.
final statusCategoriesProvider = Provider<List<WallpaperCategory>>((ref) {
  final all = switch (ref.watch(statusCatalogProvider)) {
    AsyncData(:final value) => value,
    _ => const <StatusVideo>[],
  };
  final cfg = switch (ref.watch(appConfigProvider)) {
    AsyncData(:final value) => value,
    _ => null,
  };
  final labels = <String, String>{};
  for (final s in all) {
    labels.putIfAbsent(s.category, () => s.categoryLabel);
  }
  return orderedByCms(
    labels.entries.map((e) => WallpaperCategory(e.key, e.value)).toList(),
    categoryOrderFor(cfg?.categoryOrder, 'statuses'),
    compareBrowseCategories,
  );
});

final selectedStatusCategoryProvider =
    NotifierProvider<SelectedStatusCategory, String>(
      SelectedStatusCategory.new,
    );

class SelectedStatusCategory extends Notifier<String> {
  @override
  String build() => WallpaperCategory.allSlug;

  void select(String slug) => state = slug;
}

/// The catalog filtered to the selected chip, in `feed_rank` order (nulls last, catalog order next).
List<StatusVideo> statusFeedOrder(String slug, List<StatusVideo> all) =>
    orderedByUse(
      slug == WallpaperCategory.allSlug
          ? all
          : all.where((s) => s.category == slug).toList(growable: false),
      (_) => 0,
      rank: (s) => s.feedRank,
    );

final statusFeedProvider = Provider<AsyncValue<List<StatusVideo>>>((ref) {
  final slug = ref.watch(selectedStatusCategoryProvider);
  return ref
      .watch(statusCatalogProvider)
      .whenData((all) => statusFeedOrder(slug, all));
});
