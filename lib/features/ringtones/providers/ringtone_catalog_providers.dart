import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/error/app_exception.dart';
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
/// per session is fine. An empty catalog is DATA, not an error — the screen
/// shows the designed empty state instead of a spinner or a retry wall.
final ringtoneCatalogProvider =
    AsyncNotifierProvider<RingtoneCatalogNotifier, List<Ringtone>>(
      RingtoneCatalogNotifier.new,
    );

class RingtoneCatalogNotifier extends AsyncNotifier<List<Ringtone>> {
  /// Guards a stale refresh() overwriting a newer one with older data.
  int _fetchSeq = 0;

  /// Delays between automatic re-checks while the list is parked on a network
  /// error with nothing to show, after Riverpod's own exponential-backoff
  /// retries (~13 s of quick [build] re-runs) are exhausted.
  ///
  /// Those quick retries exist for a cold-start radio/DNS blip. They do nothing
  /// for the real-world case: a user opens the tab in a lift, a metro or a dead
  /// zone, gets the error card, and then signal returns — the app has no
  /// connectivity listener anywhere, so it never noticed and the card stayed
  /// until a manual Retry. Mirrors [CatalogNotifier.offlineRecheckBackoffs];
  /// both feeds shared the defect, so both carry the fix.
  ///
  /// The ladder lengthens to two minutes and then holds, so a genuinely offline
  /// device settles into one cheap catalog fetch every two minutes rather than
  /// spinning the radio. Empty disables it (tests).
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
    // The provider outlives the screen, so the timer has to die with it or it
    // keeps waking the radio after the tab is gone. Registered per build, so a
    // rebuild (manual Retry invalidates this provider) also clears any pending
    // re-check before the new load claims its own.
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
      // Only a NETWORK failure is worth re-checking on a timer — it is the one
      // that fixes itself when the link comes back. A parse miss will fail
      // identically forever and must wait for a manual retry. The ladder resets
      // on every build() failure (Riverpod's quick retries land here too), so
      // the first slow re-check after they give up is 5 s, not two minutes.
      if (isNetworkError(e)) {
        _recheckAttempt = 0;
        _scheduleOfflineRecheck(seq);
      }
      rethrow;
    }
  }

  /// Queue the next automatic re-check after a network failure left the list
  /// with nothing to show. The timer drives [refresh], which re-reads the
  /// version pointer — a catalog published during the outage is picked up.
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

  /// Pull-to-refresh AND the offline re-check timer's retry: re-read the
  /// catalog version pointer (a just-published catalog is a new edge-cache
  /// key), then reload. On failure with data on screen the current list is
  /// kept — the indicator simply settles; the error state is reserved for a
  /// list with nothing to show, and only THAT state keeps the re-check ladder
  /// climbing.
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

  /// Sequential page drain. The repository maps a CDN miss on page 1 to an
  /// empty page, so an absent catalog resolves to an empty LIST (the designed
  /// empty state), while a genuine connectivity failure throws
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
    ..sort(compareRingtoneCategories);
});

/// Slug of the catch-all category — tracks belonging to none of the five
/// deities (Hanuman, Ganesha, gurus). Ringtones only; wallpapers have no such
/// bucket.
const String othersCategorySlug = 'others';

/// Alphabetical by label, except `others` is always LAST.
///
/// Plain alphabetical puts "Others" between "Murugan" and "Perumal", where it
/// reads as one more deity in the row rather than the leftovers bucket it is.
/// Pinning it to the end is the whole point of the category.
@visibleForTesting
int compareRingtoneCategories(WallpaperCategory a, WallpaperCategory b) {
  final aOther = a.slug == othersCategorySlug;
  final bOther = b.slug == othersCategorySlug;
  if (aOther != bOther) return aOther ? 1 : -1;
  return a.label.compareTo(b.label);
}

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
