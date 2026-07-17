import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/catalog_page.dart';
import '../../../data/models/ringtone.dart';
import '../../../data/models/wallpaper.dart';
import '../../../data/repositories/repository_providers.dart';
import '../data/cdn_ringtone_repository.dart';
import '../domain/ringtone_repository.dart';

/// CDN-backed ringtone repository (edge-cached catalog JSON, never the DB).
final ringtoneRepositoryProvider = Provider<RingtoneRepository>(
  (ref) => CdnRingtoneRepository(
    catalogClient: ref.watch(catalogHttpClientProvider),
  ),
);

/// The full ringtone catalog, drained to one list — the screen filters by
/// category client-side, mirroring the wallpaper feed (CLAUDE.md §5b: category
/// is THE browse axis; the reference's All/New tabs are deliberately NOT
/// ported). Sorted by `sort_order` then title, so authoring order holds.
///
/// No disk snapshot (unlike the wallpaper catalog): the list is a handful of
/// tiny JSON pages and the tab is not the launch surface, so a network drain
/// per session is fine. An empty catalog (nothing published yet) is DATA, not
/// an error — the screen shows the designed "coming soon" state.
final ringtoneCatalogProvider =
    AsyncNotifierProvider<RingtoneCatalogNotifier, List<Ringtone>>(
      RingtoneCatalogNotifier.new,
    );

class RingtoneCatalogNotifier extends AsyncNotifier<List<Ringtone>> {
  /// Guards a stale refresh() overwriting a newer one with older data.
  int _fetchSeq = 0;

  @override
  Future<List<Ringtone>> build() => _fetchCatalog();

  /// Pull-to-refresh: re-read the catalog version pointer (a just-published
  /// catalog is a new edge-cache key), then reload. On failure with data on
  /// screen the current list is kept — the indicator simply settles; the error
  /// state is reserved for a list with nothing to show.
  Future<void> refresh() async {
    invalidateCatalogVersion();
    final seq = ++_fetchSeq;
    try {
      final fresh = await _fetchCatalog();
      if (ref.mounted && seq == _fetchSeq) state = AsyncData(fresh);
    } catch (e, st) {
      if (!ref.mounted || seq != _fetchSeq) return;
      if (!state.hasValue) state = AsyncError(e, st);
    }
  }

  /// Sequential page drain. The repository maps a CDN miss on page 1 to an
  /// empty page, so "no catalog published yet" resolves to an empty LIST (the
  /// designed coming-soon state), while a genuine connectivity failure throws
  /// [NetworkException] out of the client and lands in AsyncError → retry.
  Future<List<Ringtone>> _fetchCatalog() async {
    final repo = ref.read(ringtoneRepositoryProvider);
    final all = <Ringtone>[];
    CatalogPage<Ringtone> page = await repo.getRingtones();
    all.addAll(page.items);
    // Defensive guard against a malformed catalog stuck on has_more.
    var guard = 0;
    while (page.hasMore && guard < 500) {
      page = await repo.getRingtones(page: page.page + 1);
      if (page.items.isEmpty) break;
      all.addAll(page.items);
      guard++;
    }
    all.sort((a, b) {
      final c = a.sortOrder.compareTo(b.sortOrder);
      return c != 0 ? c : a.title.compareTo(b.title);
    });
    return List<Ringtone>.unmodifiable(all);
  }
}

/// Categories derived from the ringtone catalog — never hardcoded, so a new
/// category server-side needs no app release. Reuses [WallpaperCategory] as
/// the chip value type so the chips row shares the wallpaper feed's contract.
final ringtoneCategoriesProvider = Provider<List<WallpaperCategory>>((ref) {
  final all = switch (ref.watch(ringtoneCatalogProvider)) {
    AsyncData(:final value) => value,
    _ => const <Ringtone>[],
  };
  final labels = <String, String>{};
  for (final r in all) {
    labels.putIfAbsent(r.category, () => r.categoryLabel);
  }
  return labels.entries
      .map((e) => WallpaperCategory(e.key, e.value))
      .toList(growable: false)
    ..sort((a, b) => a.label.compareTo(b.label));
});

/// The ringtone list's OWN selected category — deliberately separate state from
/// the wallpaper feed's, so switching tabs never cross-filters the other list.
final selectedRingtoneCategoryProvider =
    NotifierProvider<SelectedRingtoneCategory, String>(
      SelectedRingtoneCategory.new,
    );

class SelectedRingtoneCategory extends Notifier<String> {
  @override
  String build() => WallpaperCategory.allSlug;

  void select(String slug) => state = slug;
}

/// The list the screen renders: catalog filtered by the selected category.
final ringtoneFeedProvider = Provider<AsyncValue<List<Ringtone>>>((ref) {
  final slug = ref.watch(selectedRingtoneCategoryProvider);
  return ref
      .watch(ringtoneCatalogProvider)
      .whenData(
        (all) => slug == WallpaperCategory.allSlug
            ? all
            : all.where((r) => r.category == slug).toList(growable: false),
      );
});
