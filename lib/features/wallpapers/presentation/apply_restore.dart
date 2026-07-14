import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/shared_preferences_provider.dart';
import '../../../data/models/wallpaper.dart';
import '../providers/catalog_providers.dart';
import '../providers/wallpaper_apply_provider.dart';

/// Puts the user back where they were after a wallpaper apply took the app away.
///
/// Applying a wallpaper on Android 12+ makes the OS re-extract Material You
/// colours, which can RECREATE our Activity; the live-wallpaper chooser also
/// launches over us and can push us out of memory. Either way the app can come
/// back cold — on the feed, at the top, with no memory of the wallpaper the user
/// was about to set.
///
/// The apply flow already persists where it was (`pendingApply*` in
/// SharedPreferences) immediately before the native call. This is the half that
/// reads them back: without it those writes were dead weight and the restore they
/// exist for never happened.
///
/// The feed is now the home surface (no separate viewer route), so restore is a
/// category switch + a page jump on the feed's own pager — not a route push. The
/// screen implements [restoreFeedTo] to perform that jump.
///
/// Deliberately does NOT confirm success for a live apply: the OS chooser owns
/// that outcome and we cannot observe whether the user actually tapped "Set
/// wallpaper", so claiming "applied" would be a lie half the time.
mixin ApplyRestore<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  bool _restoreChecked = false;

  /// Implemented by the feed: switch to [category] and jump the pager to
  /// [index] within that filtered list. [wasLive] is false for a static apply,
  /// which is observable and completed — the feed confirms it with a toast.
  void restoreFeedTo({
    required int index,
    required String category,
    required bool wasLive,
  });

  /// Call once the catalog has data — the restore needs the item list to
  /// validate the saved index against the filtered list.
  void maybeRestoreAfterApply(List<Wallpaper> allItems) {
    if (_restoreChecked || allItems.isEmpty) return;
    _restoreChecked = true;

    final prefs = ref.read(sharedPreferencesProvider);
    if (prefs.getBool(appliedWallpaperPendingKey) != true) return;

    final index = prefs.getInt(pendingApplyPageIndexKey);
    final category = prefs.getString(pendingApplyCategoryKey);
    final wasLive = prefs.getBool(pendingApplyIsLiveKey) ?? false;

    // Consume the flags FIRST. If anything below throws, or the user backs out,
    // a stale flag must not hijack every future cold start into a jump.
    unawaited(prefs.remove(appliedWallpaperPendingKey));
    unawaited(prefs.remove(pendingApplyPageIndexKey));
    unawaited(prefs.remove(pendingApplyCategoryKey));
    unawaited(prefs.remove(pendingApplyIsLiveKey));

    if (index == null || category == null) return;

    // The saved index is a position within the FILTERED list, so validate it
    // against the same filter the feed will apply once the category is restored.
    final items = allItems
        .where((w) => w.category == category)
        .toList(growable: false);
    final list = items.isEmpty ? allItems : items;
    if (index < 0 || index >= list.length) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Restore the category chip too, so the feed lands on the wallpapers the
      // user actually left, not on "All".
      ref.read(selectedCategoryProvider.notifier).select(category);
      restoreFeedTo(index: index, category: category, wasLive: wasLive);
    });
  }
}
