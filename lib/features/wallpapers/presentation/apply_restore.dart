import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/deeplink/deep_link_target.dart';
import '../../../core/providers/shared_preferences_provider.dart';
import '../../../data/models/wallpaper.dart';
import '../../referral/data/install_referrer_service.dart';
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
  bool _deepLinkChecked = false;

  /// Implemented by the feed: switch to [category] and jump the pager to
  /// [index] within that filtered list. [wasLive] is false for a static apply,
  /// which is observable and completed — the feed confirms it with a toast.
  void restoreFeedTo({
    required int index,
    required String category,
    required bool wasLive,
  });

  /// Implemented by the feed: jump the pager to [index] in the list it is
  /// currently serving, with no toast.
  ///
  /// Separate from [restoreFeedTo] rather than a flag on it: that method's
  /// toast confirms a completed APPLY, and firing it for a deep link would tell
  /// someone who just tapped a shared link that their wallpaper was set.
  void jumpFeedTo({required int index});

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

    // The saved index is a position within the list the feed SERVES for that
    // chip, so validate it against the feed's own ordering — not against the raw
    // catalog. For All that ordering is the curated head plus a stable shuffle,
    // not catalog order (feedOrder), and validating against catalog order would
    // restore the user onto a different wallpaper. An empty result means the saved category is no
    // longer in the catalog: nothing to restore to, so leave the feed alone
    // rather than jump into a list that isn't there.
    final list = feedOrder(category, allItems);
    if (index < 0 || index >= list.length) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Restore the category chip too, so the feed lands on the wallpapers the
      // user actually left, not on "All".
      ref.read(selectedCategoryProvider.notifier).select(category);
      restoreFeedTo(index: index, category: category, wasLive: wasLive);
    });
  }

  /// Open the wallpaper a share or ad link asked for, if any.
  ///
  /// Call alongside [maybeRestoreAfterApply], once the catalog has data — this
  /// needs the item list to turn an id into the page index the pager takes.
  ///
  /// Always lands on **All**, never the wallpaper's own category: All is the
  /// only chip guaranteed to contain every row, and dropping someone into a
  /// filtered feed they never chose would hide everything else the link was
  /// meant to introduce them to.
  ///
  /// A miss is silent and normal, not an error — the link may point at a
  /// wallpaper that has since been unpublished, or at a catalog this build has
  /// not drained yet. The user simply gets the ordinary feed.
  void maybeOpenDeepLink(List<Wallpaper> allItems) {
    if (_deepLinkChecked || allItems.isEmpty) return;
    _deepLinkChecked = true;

    final wallpaperId = ArulDeepLink.consume();
    if (wallpaperId == null) return;

    // Clear the deferred copy too. ArulDeepLink and the pref are seeded together
    // (main.dart) precisely because either can win the startup race; consuming
    // one without the other would re-open this wallpaper on the next launch.
    unawaited(
      InstallReferrerService(
        ref.read(sharedPreferencesProvider),
      ).clearPendingWallpaper(),
    );

    const all = WallpaperCategory.allSlug;
    final list = feedOrder(all, allItems);
    final index = list.indexWhere((w) => w.id == wallpaperId);
    if (index < 0) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(selectedCategoryProvider.notifier).select(all);
      jumpFeedTo(index: index);
    });
  }
}
