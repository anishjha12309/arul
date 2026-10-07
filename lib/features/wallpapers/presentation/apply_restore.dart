import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/analytics/analytics_provider.dart';
import '../../../core/deeplink/deep_link_target.dart';
import '../../../core/deeplink/install_referrer_service.dart';
import '../../../core/providers/shared_preferences_provider.dart';
import '../../../data/models/wallpaper.dart';
import '../providers/catalog_providers.dart';
import '../providers/wallpaper_apply_provider.dart';

/// Puts the user back where they were after a wallpaper apply took the app away.
/// An Android 12+ apply re-extracts Material You colours, which can RECREATE our Activity.
/// The live-wallpaper chooser also launches over us and can push us out of memory.
/// Either way the app comes back COLD — on the feed, at the top, with no memory of the wallpaper.
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
  /// Call alongside [maybeRestoreAfterApply], once the catalog has data — an id needs a page index.
  void maybeOpenDeepLink(List<Wallpaper> allItems) {
    if (allItems.isEmpty) return;

    final target = ArulDeepLink.consumeWallpaper(
      shell: ArulShellScope.of(context),
    );
    if (target == null) return;

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
