import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/error/app_exception.dart';
import '../../../data/models/catalog_page.dart';
import '../../../data/models/ringtone.dart';
import '../../../data/models/wallpaper.dart';
import '../../../data/repositories/repository_providers.dart';
import '../../wallpapers/providers/catalog_providers.dart' show orderedByUse;
import '../data/cdn_ringtone_repository.dart';
import '../domain/ringtone_repository.dart';

/// CDN-backed ringtone repository (edge-cached catalog JSON, never the DB).
final ringtoneRepositoryProvider = Provider<RingtoneRepository>(
  (ref) => CdnRingtoneRepository(
    catalogClient: ref.watch(catalogHttpClientProvider),
  ),
);

/// The full ringtone catalog, drained to one list — the screen filters by category client-side.
///
/// Category is THE browse axis (CLAUDE.md §5b); the reference's All/New tabs are NOT ported.
/// Sorted by `sort_order` then title, so authoring order holds.
/// NO disk snapshot: a handful of tiny pages, and this tab is not the launch surface.
/// [AppShell] warms it post-first-frame -> the drain has usually finished before the user arrives.
/// An empty catalog is DATA, not an error -> the designed empty state, never a spinner or a wall.
final ringtoneCatalogProvider =
    AsyncNotifierProvider<RingtoneCatalogNotifier, List<Ringtone>>(
      RingtoneCatalogNotifier.new,
    );

class RingtoneCatalogNotifier extends AsyncNotifier<List<Ringtone>> {
  /// Guards a stale refresh() overwriting a newer one with older data.
  int _fetchSeq = 0;

  /// Bounded fan-out for the page drain, matching the wallpaper [CatalogNotifier] -> no radio flood.
  static const _maxConcurrentPages = 4;

  /// Delays between automatic re-checks while the list is parked on a network error, showing nothing.
  ///
  /// Riverpod's own ~13 s of quick retries cover a cold-start radio or DNS blip, and nothing else.
  /// A user in a lift gets the error card, signal returns, and no connectivity listener notices.
  /// The card then stayed until a manual Retry -> this ladder is the fix, mirrored in both feeds.
  /// It lengthens to two minutes and HOLDS -> an offline device settles, never spins the radio.
  /// Empty disables it (tests).
  @visibleForTesting
  static List<Duration> offlineRecheckBackoffs = const [
    Duration(seconds: 5),
    Duration(seconds: 15),
    Duration(seconds: 30),
    Duration(seconds: 60),
    Duration(seconds: 120),
  ];

  Timer? _recheckTimer;
  int _recheckAttempt = 0;

  @override
  Future<List<Ringtone>> build() async {
    // The provider outlives the screen -> the timer must die with it, or it wakes the radio after.
    // Registered per build, so a rebuild also clears any pending re-check before the new load.
    ref.onDispose(() {
      _recheckTimer?.cancel();
      _recheckTimer = null;
    });

    final seq = ++_fetchSeq;
    try {
      final items = await _fetchCatalog();
      _recheckAttempt = 0;
      return items;
    } catch (e) {
      // Only a NETWORK failure is worth a timer — it is the one that fixes itself.
      // A parse miss fails identically forever and must wait for a manual retry.
      // The ladder resets on every build() failure -> the first slow re-check is 5 s, not two minutes.
      if (isNetworkError(e)) {
        _recheckAttempt = 0;
        _scheduleOfflineRecheck(seq);
      }
      rethrow;
    }
  }

  /// Queue the next automatic re-check after a network failure left the list with nothing to show.
  /// The timer drives [refresh], which re-reads the version pointer -> an outage-time publish lands.
  void _scheduleOfflineRecheck(int seq) {
    _recheckTimer?.cancel();
    final ladder = offlineRecheckBackoffs;
    if (ladder.isEmpty) return;
    final delay = ladder[_recheckAttempt.clamp(0, ladder.length - 1)];
    _recheckAttempt++;
    _recheckTimer = Timer(delay, () {
      // A newer load (manual retry, pull-refresh, rebuild) supersedes us.
      if (seq != _fetchSeq) return;
      unawaited(refresh());
    });
  }

  /// Pull-to-refresh AND the offline timer's retry — re-read the version pointer, then reload.
  /// A just-published catalog is a new edge-cache key.
  /// On failure WITH data on screen the current list is kept and the indicator simply settles.
  /// The error state is reserved for a list with nothing to show, and only that climbs the ladder.
  Future<void> refresh() async {
    invalidateCatalogVersion();
    final seq = ++_fetchSeq;
    try {
      final fresh = await _fetchCatalog();
      // The link is up — the next outage starts the ladder from the top.
      _recheckAttempt = 0;
      _recheckTimer?.cancel();
      if (ref.mounted && seq == _fetchSeq) state = AsyncData(fresh);
    } catch (e, st) {
      if (!ref.mounted || seq != _fetchSeq) return;
      if (!state.hasValue) {
        state = AsyncError(e, st);
        if (isNetworkError(e)) _scheduleOfflineRecheck(seq);
      }
    }
  }

  /// Drains the full catalog — page 1 carries `total_pages`, then the rest, at most
  /// [_maxConcurrentPages] in flight, reassembled in page order.
  ///
  /// A sequential drain measured ~5 s on first open: 8 pages, one CDN round trip each.
  /// The repository maps a CDN miss to an EMPTY page -> an absent catalog is an empty LIST.
  /// A genuine connectivity failure throws [NetworkException] instead -> AsyncError, then retry.
  /// An empty later page means end-of-pages or a transient miss -> everything before it is served.
  Future<List<Ringtone>> _fetchCatalog() async {
    final repo = ref.read(ringtoneRepositoryProvider);

    final first = await repo.getRingtones();
    final all = [...first.items];
    // Defensive cap against a malformed catalog advertising an absurd page count.
    final totalPages = first.totalPages.clamp(0, 500);
    if (first.hasMore && totalPages > 1) {
      // Worker pool over pages 2..totalPages, slotted BY PAGE -> order is completion-independent.
      final slots = List<CatalogPage<Ringtone>?>.filled(totalPages - 1, null);
      var next = 2;
      Future<void> worker() async {
        while (true) {
          final page = next++;
          if (page > totalPages) return;
          slots[page - 2] = await repo.getRingtones(page: page);
        }
      }

      final workers = (totalPages - 1).clamp(1, _maxConcurrentPages);
      await Future.wait([for (var i = 0; i < workers; i++) worker()]);

      for (final page in slots) {
        if (page == null || page.items.isEmpty) break;
        all.addAll(page.items);
      }
    }

    all.sort((a, b) {
      final c = a.sortOrder.compareTo(b.sortOrder);
      return c != 0 ? c : a.title.compareTo(b.title);
    });
    return List<Ringtone>.unmodifiable(all);
  }
}

/// Categories DERIVED from the ringtone catalog -> a new category server-side needs no app release.
/// Reuses [WallpaperCategory] as the chip value type, so the chips row shares the feed's contract.
final ringtoneCategoriesProvider = Provider<List<WallpaperCategory>>((ref) {
  final all = switch (ref.watch(ringtoneCatalogProvider)) {
    AsyncData(:final value) => value,
    _ => const <Ringtone>[],
  };
  final cfg = switch (ref.watch(appConfigProvider)) {
    AsyncData(:final value) => value,
    _ => null,
  };
  final labels = <String, String>{};
  for (final r in all) {
    labels.putIfAbsent(r.category, () => r.categoryLabel);
  }
  // A CMS order wins OUTRIGHT here, `others` included: dragging it off the end is a
  // deliberate act, and silently overriding it would be the CMS showing one order and
  // the app another. With no CMS order, `others`-last still holds.
  return orderedByCms(
    labels.entries.map((e) => WallpaperCategory(e.key, e.value)).toList(),
    categoryOrderFor(cfg?.categoryOrder, 'ringtones'),
    compareRingtoneCategories,
  );
});

/// Slug of the catch-all category — tracks belonging to none of the five deities.
/// Ringtones only; wallpapers have no such bucket.
const String othersCategorySlug = 'others';

/// [compareBrowseCategories] — Sivan first, then alphabetical — except `others` is always LAST.
///
/// Plain alphabetical puts "Others" between "Murugan" and "Perumal", reading as one more deity.
/// Pinning it to the end is the whole point of the category.
/// The rest of the order is the wallpaper row's, shared so the two tabs cannot drift.
@visibleForTesting
int compareRingtoneCategories(WallpaperCategory a, WallpaperCategory b) {
  final aOther = a.slug == othersCategorySlug;
  final bOther = b.slug == othersCategorySlug;
  if (aOther != bOther) return aOther ? 1 : -1;
  return compareBrowseCategories(a, b);
}

/// The ringtone list's OWN selected category — separate state, so a tab switch never cross-filters.
final selectedRingtoneCategoryProvider =
    NotifierProvider<SelectedRingtoneCategory, String>(
      SelectedRingtoneCategory.new,
    );

class SelectedRingtoneCategory extends Notifier<String> {
  @override
  String build() => WallpaperCategory.allSlug;

  void select(String slug) => state = slug;
}

/// The list the screen serves for [slug] — the ONE definition of ringtone order.
///
/// The ringtone twin of `feedOrder()`: filtered by category, then rank, then most-SET, then position.
/// Identical rule to the wallpaper feed through the same [orderedByUse] -> the two cannot drift.
/// See catalog_providers.dart for why rank is nulls-last and the position tiebreaker is load-bearing.
/// EVERY chip gets the comparator, All included — a category is All restricted to that category.
/// A deep link resolves its row index through this too: raw catalog order would scroll elsewhere.
List<Ringtone> ringtoneFeedOrder(String slug, List<Ringtone> all) =>
    orderedByUse(
      slug == WallpaperCategory.allSlug
          ? all
          : all.where((r) => r.category == slug).toList(growable: false),
      (r) => r.setCount,
      rank: (r) => r.feedRank,
    );

/// The list the screen renders: [ringtoneFeedOrder] for the selected category.
final ringtoneFeedProvider = Provider<AsyncValue<List<Ringtone>>>((ref) {
  final slug = ref.watch(selectedRingtoneCategoryProvider);
  return ref
      .watch(ringtoneCatalogProvider)
      .whenData((all) => ringtoneFeedOrder(slug, all));
});
