import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/analytics/analytics_provider.dart';
import '../../../core/deeplink/deep_link_target.dart';
import '../../../core/providers/shared_preferences_provider.dart';
import '../../../data/models/wallpaper.dart';
import '../../referral/data/install_referrer_service.dart';
import '../providers/catalog_providers.dart';
import '../providers/wallpaper_apply_provider.dart';

/// Puts the user back where they were after a wallpaper apply took the app away.
///
/// An Android 12+ apply re-extracts Material You colours, which can RECREATE our Activity.
/// The live-wallpaper chooser also launches over us and can push us out of memory.
/// Either way the app comes back COLD — on the feed, at the top, with no memory of the wallpaper.
/// The apply flow persists `pendingApply*` immediately before the native call.
/// This is the half that reads them back — without it those writes are dead weight.
/// The feed is the home surface -> restore is a category switch and a pager jump, not a route push.
/// Deliberately does NOT confirm success for a LIVE apply — the OS chooser owns that outcome.
/// We cannot observe the user's "Set wallpaper" tap, so claiming "applied" would be a lie half the time.
mixin ApplyRestore<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  bool _restoreChecked = false;

  /// Implemented by the feed — switch to [category] and jump the pager to [index] in that list.
  /// [wasLive] false is a STATIC apply, observable and completed -> the feed confirms it with a toast.
  void restoreFeedTo({
    required int index,
    required String category,
    required bool wasLive,
  });

  /// Implemented by the feed — jump the pager to [index] in the list it serves, with NO toast.
  ///
  /// Separate from [restoreFeedTo], not a flag on it: that toast confirms a completed APPLY.
  /// Firing it for a deep link would tell someone who tapped a link that their wallpaper was set.
  void jumpFeedTo({required int index});

  /// Call once the catalog has data — the restore validates the saved index against the list.
  void maybeRestoreAfterApply(List<Wallpaper> allItems) {
    if (_restoreChecked || allItems.isEmpty) return;
    _restoreChecked = true;

    final prefs = ref.read(sharedPreferencesProvider);
    if (prefs.getBool(appliedWallpaperPendingKey) != true) return;

    final index = prefs.getInt(pendingApplyPageIndexKey);
    final category = prefs.getString(pendingApplyCategoryKey);
    final wasLive = prefs.getBool(pendingApplyIsLiveKey) ?? false;

    // Consume the flags FIRST -> a throw, or a back-out, must not hijack every future cold start.
    unawaited(prefs.remove(appliedWallpaperPendingKey));
    unawaited(prefs.remove(pendingApplyPageIndexKey));
    unawaited(prefs.remove(pendingApplyCategoryKey));
    unawaited(prefs.remove(pendingApplyIsLiveKey));

    if (index == null || category == null) return;

    // The saved index is a position in the list the feed SERVES for that chip.
    // So validate against `feedOrder`, never raw catalog order — they differ, and it would misland.
    // An empty result means the saved category left the catalog -> leave the feed alone.
    final list = feedOrder(category, allItems);
    if (index < 0 || index >= list.length) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Restore the category chip too -> the feed lands where the user left, not on "All".
      ref.read(selectedCategoryProvider.notifier).select(category);
      restoreFeedTo(index: index, category: category, wasLive: wasLive);
    });
  }

  /// Open the wallpaper a share or ad link asked for, if any.
  ///
  /// Call alongside [maybeRestoreAfterApply], once the catalog has data — an id needs a page index.
  /// Always lands on **All**, never the wallpaper's own category.
  /// All is the only chip with every row, and a filtered feed hides what the link was introducing.
  /// A miss is silent and normal — the wallpaper may be unpublished, or the catalog not yet drained.
  /// Re-checked on EVERY build with a catalog, unlike [maybeRestoreAfterApply]'s one-shot.
  /// A warm App Link or a deferred delivery can park a target long after the first catalog.
  /// A once-per-mount flag dropped both on the floor for the whole session.
  /// Nothing repeats, because [ArulDeepLink.consumeWallpaper] is read-and-clear.
  /// It takes ONLY a wallpaper — the feed builds before the shell switches tabs, so a ringtone passes.
  void maybeOpenDeepLink(List<Wallpaper> allItems) {
    if (allItems.isEmpty) return;

    final target = ArulDeepLink.consumeWallpaper();
    if (target == null) return;

    // ArulDeepLink and the pref are seeded together because either can win the startup race.
    // Consuming one without the other would re-open this wallpaper on the next launch.
    unawaited(
      InstallReferrerService(
        ref.read(sharedPreferencesProvider),
      ).clearPendingTarget(),
    );

    const all = WallpaperCategory.allSlug;
    final list = feedOrder(all, allItems);
    final index = list.indexWhere((w) => w.id == target.id);
    if (index < 0) return;

    // GA4-only — which delivery channel actually lands people on the content they tapped.
    ref
        .read(analyticsServiceProvider)
        .track('deep_link_opened', properties: target.analyticsProperties);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(selectedCategoryProvider.notifier).select(all);
      jumpFeedTo(index: index);
    });
  }
}
