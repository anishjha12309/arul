import 'dart:math' as math;

import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/l10n/app_localizations.dart';
import '../../../core/analytics/analytics_provider.dart';
import '../../../core/analytics/analytics_service.dart';
import '../../../core/config/app_config.dart';
import '../../../core/connectivity/connectivity_provider.dart';
import '../../../app/widgets/arul_toast.dart';
import '../../../app/widgets/gopuram_mark.dart';
import '../../../data/models/wallpaper.dart';
import '../../../theme/arul_tokens.dart';
import '../../premium/presentation/premium_sheet.dart';
import '../../premium/providers/entitlement_provider.dart';
import '../data/wallpaper_apply_service.dart';
import '../providers/catalog_providers.dart';
import '../providers/video_preload_provider.dart';
import '../providers/wallpaper_apply_provider.dart';
import '../providers/wallpaper_share_provider.dart';
import 'apply_restore.dart';
import 'apply_sheet.dart';
import 'feed_card_geometry.dart';
import 'feed_states.dart';
import 'premium_nudge.dart';
import 'video_preload_controller.dart';
import 'viewer_media.dart';

/// The home surface: a Shorts-style vertical reel of wallpapers, one full-bleed
/// page each (Spec > Reel feed). The old grid + separate viewer are gone —
/// this pager IS the browse experience.
///
/// Chromeless by design: category chips float on the top scrim, an icon-only
/// action rail hugs the right edge, and the current item's meta sits bottom-left.
/// All three recede on a swipe and settle back on rest. Browse and preview are
/// free; Apply and Share are premium-gated.
class FeedScreen extends ConsumerStatefulWidget {
  const FeedScreen({super.key});

  @override
  ConsumerState<FeedScreen> createState() => _FeedScreenState();
}

class _FeedScreenState extends ConsumerState<FeedScreen>
    with ApplyRestore, WidgetsBindingObserver {
  /// Built lazily from the measured geometry rather than in initState:
  /// `viewportFraction` is final on PageController, and the fraction can only be
  /// solved once the reel's real height is known.
  ///
  /// With `padEnds: false` the fraction IS the page extent as a share of the
  /// viewport, so `pageExtent / height` pins each snapped page flush to the top
  /// and leaves the remainder showing as the next card's peek. Stock PageView
  /// throughout — snap, drag and fling geometry are untouched.
  PageController? _pager;
  double? _pagerFraction;

  PageController _pagerFor(FeedCardGeometry geo, double height) {
    final fraction = height <= 0
        ? 1.0
        : (geo.pageExtent / height).clamp(0.2, 1.0);
    if (_pager != null && _pagerFraction == fraction) return _pager!;
    final previous = _pager;
    _pagerFraction = fraction;
    _pager = PageController(initialPage: _index, viewportFraction: fraction);
    // The outgoing controller is still attached to the PageView being replaced
    // this frame; disposing it inline would throw. Let the frame land first.
    if (previous != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => previous.dispose());
    }
    return _pager!;
  }

  /// Captured in initState, NOT read lazily via `ref.read`: `ref` is unusable
  /// from `dispose()` in Riverpod 3, so a `ref.read` there silently fails to
  /// reach the controller — exactly how `detach()` never runs and the pool keeps
  /// a populated list after the feed closes. Hold the reference.
  late final VideoPreloadController _video;

  /// Held from initState for the same reason as [_video]: the feed-session
  /// summary is flushed from `dispose()`, where `ref` is unusable in Riverpod 3.
  late final AnalyticsService _analytics;

  int _index = 0;

  // ── Feed-session counters ──────────────────────────────────────────────────
  //
  // Rolled up into ONE `feed_session_ended` event instead of one PostHog event
  // per card. PostHog bills per event and NOT per property, so a single event
  // carrying counts answers the same questions (scroll depth, live/static mix,
  // session length) at a small fraction of the billed volume. The per-card
  // `wallpaper_engaged` still fires for GA4, which is free and unsampled.

  /// A card counts as engaged only after the user has dwelled on it for
  /// [_dwellThreshold] — a swipe that passes through is not engagement. Reset on
  /// every page change.
  Timer? _dwellTimer;
  static const _dwellThreshold = Duration(seconds: 2);

  int _engagedCount = 0;
  int _engagedLive = 0;
  int _maxDepth = 0;
  DateTime? _feedSessionStart;

  /// The filtered list currently handed to the pager + video pool. Compared by
  /// CONTENT (ordered item ids), not identity: feedProvider re-emits a NEW list
  /// identity on every catalogProvider change (a background revalidate or
  /// pull-refresh), and an identity-only check reset the browse position on each
  /// of those. A resync only jumps/re-points when the items actually change.
  List<Wallpaper>? _servedList;

  /// Set by [restoreFeedTo] after an apply-driven cold restart: the page to jump
  /// to once the restored category's list lands. Consumed by [_syncFeed].
  int? _pendingRestoreIndex;

  /// The gate nudge shows at most ONCE per session; every gated tap after that
  /// opens the premium sheet.
  bool _nudgeShown = false;
  PremiumGateAction? _nudge;
  int _nudgeSeq = 0;

  /// The gate AWAITS `entitlementProvider.future` (CLAUDE.md §5): a loading
  /// snapshot must never bounce a premium user to the paywall on a cold start.
  /// A failed fetch gates closed — the Worker's signed-url check remains the
  /// authoritative gate either way.
  Future<bool> _isPremium() async {
    try {
      return await ref.read(entitlementProvider.future);
    } catch (_) {
      return false;
    }
  }

  @override
  void initState() {
    super.initState();
    _video = ref.read(videoPreloadControllerProvider);
    _analytics = ref.read(analyticsServiceProvider);
    _feedSessionStart = DateTime.now();
    // This screen lives in a StatefulShellRoute.indexedStack, so it is kept
    // alive across tab switches and in practice only disposes when the app dies
    // — dispose() alone would almost never flush the summary. Backgrounding is
    // the real end-of-session signal, so observe it.
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    _dwellTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    // Backstop for the rare path where the screen really is torn down without
    // the app being backgrounded first.
    _flushFeedSession();
    _pager?.dispose();
    // Do NOT dispose the controller — it is app-scoped, and disposing here would
    // race the Android 12+ Activity recreate a wallpaper apply can trigger.
    // detach() returns the decoders AND clears the list so a later
    // background/resume cannot spin the pool up behind a screen with no video.
    _video.detach();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // `paused` (and `hidden` on the newer lifecycle) is the last callback we are
    // guaranteed before the process can be killed, so it is the only reliable
    // place to close out a feed session.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _flushFeedSession();
    } else if (state == AppLifecycleState.resumed) {
      // Returning to the foreground starts a NEW session rather than resuming
      // the closed one, so the `seconds` property stays meaningful.
      _feedSessionStart = DateTime.now();
    }
  }

  /// Emits one `feed_session_ended` summary and resets the counters.
  ///
  /// Silent when the user never dwelled on a card, so opening the tab and
  /// swiping straight back out does not register as a session. Resetting after
  /// the emit makes this safe to call more than once (background → foreground →
  /// background) without double-counting.
  void _flushFeedSession() {
    if (_engagedCount == 0) return;
    final start = _feedSessionStart;
    _analytics.track(
      'feed_session_ended',
      properties: {
        'cards_engaged': _engagedCount,
        'cards_engaged_live': _engagedLive,
        'cards_engaged_static': _engagedCount - _engagedLive,
        'max_depth': _maxDepth,
        'seconds': start == null
            ? 0
            : DateTime.now().difference(start).inSeconds,
      },
    );
    _engagedCount = 0;
    _engagedLive = 0;
    _maxDepth = 0;
    _feedSessionStart = DateTime.now();
  }

  /// Starts the dwell clock for the card that just landed. Fires the per-card
  /// `wallpaper_engaged` (GA4-only — it is not on the PostHog allow-list) and
  /// folds the card into the session counters that `feed_session_ended` reports.
  void _onCardSettled(int index, Wallpaper wallpaper) {
    _dwellTimer?.cancel();
    _dwellTimer = Timer(_dwellThreshold, () {
      if (!mounted) return;
      _engagedCount++;
      if (wallpaper.kind == WallpaperKind.live) _engagedLive++;
      if (index > _maxDepth) _maxDepth = index;
      _analytics.track(
        'wallpaper_engaged',
        properties: {
          'wallpaper_id': wallpaper.id,
          'category': wallpaper.category,
          // Spelled as `wallpaper_shared` / `wallpaper_applied` spell it, so the
          // engagement → apply funnel is joinable on the same key.
          'type': wallpaper.kind.name,
        },
      );
    });
  }

  // ─── List sync ─────────────────────────────────────────────────────────────

  /// Re-point the pager + video pool at [items] whenever the filtered list
  /// changes (category switch, first data, or an apply-restore jump).
  void _syncFeed(List<Wallpaper> items) {
    final previous = _servedList;

    // Defect E: a background revalidate (cache-first startup path) or a
    // pull-refresh that returns EQUIVALENT content re-emits a new list identity
    // with the same items. Detecting change by identity reset _index to 0,
    // jumped the pager, and re-pointed the video pool mid-browse. When the items
    // are unchanged, keep the user exactly where they are — just hand the pool
    // the fresh objects so a same-id item whose URL changed still re-opens
    // (reconcile is a no-op when nothing changed, so there is no flicker). Never
    // when an apply-restore jump is pending: that must still land on its index.
    if (previous != null &&
        _pendingRestoreIndex == null &&
        _sameContent(previous, items)) {
      _servedList = items;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _video.setWallpapers(items, initialIndex: _index);
      });
      return;
    }

    _servedList = items;

    final target =
        (_pendingRestoreIndex != null &&
            _pendingRestoreIndex! >= 0 &&
            _pendingRestoreIndex! < items.length)
        ? _pendingRestoreIndex!
        : 0;
    _pendingRestoreIndex = null;
    _index = target;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final pager = _pager;
      if (pager != null && pager.hasClients) pager.jumpToPage(target);
      // reclaim: the pool may hold no decoders (released by a prior apply); the
      // index goes in WITH the list so the pool opens the right clip first.
      _video
        ..reclaimDecoders()
        ..setWallpapers(items, initialIndex: target)
        ..onPageChanged(target);
      // Start the dwell clock for the card the user LANDS on. onPageChanged only
      // fires on a swipe, so without this the first card of every session — the
      // one card guaranteed to be seen — would never count as engaged, and a
      // session spent on it alone would emit nothing at all.
      if (target < items.length) _onCardSettled(target, items[target]);
    });
  }

  /// Whether two filtered feeds hold the same items in the same order (by id).
  /// A category switch, or a catalog rebuild that added/removed/reordered items,
  /// changes this; a revalidate that re-fetched the identical catalog does not.
  static bool _sameContent(List<Wallpaper> a, List<Wallpaper> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id) return false;
    }
    return true;
  }

  @override
  void restoreFeedTo({
    required int index,
    required String category,
    required bool wasLive,
  }) {
    // The category was already selected by the mixin; its list recompute drives
    // _syncFeed, which will land on this index.
    setState(() => _pendingRestoreIndex = index);
    if (!wasLive) {
      showArulToast(context, AppLocalizations.of(context).applied);
    }
  }

  /// Pull-to-refresh: an authoritative network reload. `refresh()` re-reads
  /// the version pointer and BYPASSES the serve-cached-first fast path (a bare
  /// invalidate would re-emit the disk snapshot instantly and the indicator
  /// would settle without fresh data). It never throws: on failure with data
  /// on screen the current feed is kept; the AsyncError branch renders retry
  /// only when there is nothing to show. Fresh data cascades to feedProvider.
  Future<void> _refreshCatalog() =>
      ref.read(catalogProvider.notifier).refresh();

  /// Ported from the reference feed: warm the NEXT item's full image when it
  /// is static, so a static→static swipe paints from cache instead of
  /// shimmering through the whole download. Live items are prefetched as bytes
  /// ahead of time by the prefetch service's data window, not here. Same URL
  /// AND the same decode width as [ViewerMedia]'s full-resolution layer, so
  /// this precache and the page's render share ONE image-cache entry.
  void _precacheNextStatic(List<Wallpaper> items, int index) {
    final next = index + 1;
    if (next >= items.length || items[next].kind != WallpaperKind.image) {
      return;
    }
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final fullWidth = (MediaQuery.sizeOf(context).width * dpr).round();
    precacheImage(
      ResizeImage.resizeIfNeeded(
        fullWidth,
        null,
        CachedNetworkImageProvider(items[next].url(AppConfig.cdnBaseUrl)),
      ),
      context,
      // Never throws into the framework; the real render path keeps its own
      // self-healing retry regardless.
      onError: (_, _) {},
    );
  }

  // ─── Premium gate ────────────────────────────────────────────────────────────

  Future<void> _onAction(PremiumGateAction action, Wallpaper w) async {
    final prem = await _isPremium();
    if (prem) {
      switch (action) {
        case PremiumGateAction.apply:
          unawaited(_doApply(w));
        case PremiumGateAction.share:
          unawaited(_doShare(w));
      }
      return;
    }
    if (!mounted) return;
    // Free user: nudge once, then the sheet. Either way the blocked verb is
    // tracked (docs/edge-cases.md).
    ref
        .read(analyticsServiceProvider)
        .track(
          '${action.source}_blocked_premium',
          properties: {'wallpaper_id': w.id, 'category': w.category},
        );
    if (!_nudgeShown) {
      setState(() {
        _nudgeShown = true;
        _nudge = action;
        _nudgeSeq++;
      });
    } else {
      unawaited(PremiumSheet.show(context, source: action.source));
    }
  }

  // ─── Apply / share (ported plumbing) ─────────────────────────────────────────

  Future<void> _doApply(Wallpaper w) async {
    final l10n = AppLocalizations.of(context);

    // Live wallpapers skip our target sheet: Android's live-wallpaper chooser
    // asks Home/Lock/Both itself and is the one that decides.
    final ApplyTarget target;
    if (w.kind == WallpaperKind.live) {
      target = ApplyTarget.both;
    } else {
      final picked = await ApplySheet.show(context);
      if (picked == null || !mounted) return; // dismissed — not a failure
      target = picked;
    }

    await ref
        .read(wallpaperApplyProvider.notifier)
        .apply(
          w,
          target: target,
          feedPageIndex: _index,
          category: w.category,
          // The wallpaper engine / chooser preview is about to need the hardware
          // decoders the feed holds; on a budget SoC there are only a handful.
          releaseVideoDecoders: _video.releaseDecoders,
        );

    if (!mounted) return;
    final state = ref.read(wallpaperApplyProvider);
    switch (state) {
      case WallpaperApplySuccess():
        showArulToast(context, l10n.applied);
        _video.reclaimDecoders();
      case WallpaperApplyError(:final isNetwork, :final premiumRequired):
        if (premiumRequired) {
          // The subscription lapsed (or was refunded) mid-session and the
          // server's live check caught it. A generic toast here is a dead
          // end — retrying fails identically forever — so send the user
          // somewhere they can actually act.
          ref
              .read(analyticsServiceProvider)
              .track(
                'apply_blocked_premium',
                properties: {'wallpaper_id': w.id, 'category': w.category},
              );
          unawaited(context.push('/premium?source=apply'));
        } else {
          showArulToast(
            context,
            isNetwork ? l10n.offlineBody : l10n.errorGeneric,
          );
        }
        _video.reclaimDecoders();
      // Idle = the OS live-wallpaper chooser is open OVER us and owns the
      // outcome. Say nothing (we cannot observe the tap) and do NOT reclaim the
      // decoders here — that would race the chooser's preview for the same
      // codecs. The lifecycle resume path reclaims on return.
      case _:
        break;
    }
    ref.read(wallpaperApplyProvider.notifier).reset();
  }

  Future<void> _doShare(Wallpaper w) async {
    final l10n = AppLocalizations.of(context);
    await ref
        .read(wallpaperShareProvider.notifier)
        .share(w, buildCaption: l10n.wallpaperShareCaption);

    if (!mounted) return;
    final state = ref.read(wallpaperShareProvider);
    if (state is WallpaperShareError) {
      if (state.premiumRequired) {
        // Same dead end as apply — route to where they can resubscribe.
        ref
            .read(analyticsServiceProvider)
            .track(
              'share_blocked_premium',
              properties: {'wallpaper_id': w.id, 'category': w.category},
            );
        unawaited(context.push('/premium?source=share'));
      } else {
        showArulToast(
          context,
          state.isNetwork ? l10n.offlineBody : l10n.errorGeneric,
        );
      }
      ref.read(wallpaperShareProvider.notifier).reset();
    }
  }

  // ─── Build ───────────────────────────────────────────────────────────────────

  /// The frame-owned breathing room between the chips row and the divider.
  static const _chipsGap = 10.0;

  /// Distance from the header's hairline divider down to the top of the card —
  /// Pakiza's header gap, so the reel starts the way its does.
  ///
  /// The divider is what makes the scroll exit read as intentional: the reel's
  /// clip line — the one place an outgoing card can vanish — sits EXACTLY under
  /// a drawn boundary, so mid-scroll a card slides beneath a line you can see.
  /// No gradient, no fade — a pure clip at a visible edge.
  static const _reelTopGap = FeedCardGeometry.gap;

  static const _cardRadius = FeedCardGeometry.radius;

  /// The card's resting geometry for a reel [height] — see [FeedCardGeometry].
  FeedCardGeometry _geometryFor(BuildContext context, double height) =>
      FeedCardGeometry.resolve(context, reelHeight: height);

  @override
  Widget build(BuildContext context) {
    // Restore after an apply-driven cold restart, once the full catalog is in.
    if (ref.watch(catalogProvider) case AsyncData(:final value)) {
      maybeRestoreAfterApply(value);
    }

    final feed = ref.watch(feedProvider);

    // Keep the entitlement warm for the whole time the feed is up. It is
    // autoDispose, and the gate only ever `read`s it from inside a tap handler —
    // so with no listener it was disposed and RE-FETCHED on every Apply/Share
    // tap, making each gated tap wait on a live /me/subscription round trip
    // (12s timeout) before any UI moved. Watching it here resolves it once, at
    // feed load, so `_isPremium()` hands back a cached value instantly.
    ref.watch(entitlementProvider);

    // Offline gate (product decision: "the instant the internet is out, no
    // wallpapers"). Fires only on a KNOWN offline result — a loading snapshot
    // (`.value == null`) or a failed probe keeps the normal online path, so a
    // slow first connectivity check never flashes the offline screen over a
    // live network. When offline the whole reel — browse AND the Apply/Share
    // rail — is unreachable, which also means the premium gate can't hang on an
    // offline signed-url/subscription call.
    final offline = ref.watch(isOnlineProvider).value == false;

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final frameColor = isDark ? ArulTokens.darkSurface : ArulTokens.ivory;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      // The frame follows the app theme, so the status/nav icons do too.
      value: SystemUiOverlayStyle(
        statusBarColor: const Color(0x00000000),
        statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
        systemNavigationBarColor: const Color(0x00000000),
        systemNavigationBarIconBrightness: isDark
            ? Brightness.light
            : Brightness.dark,
        systemNavigationBarContrastEnforced: false,
      ),
      child: Scaffold(
        backgroundColor: frameColor,
        body: SafeArea(
          child: Column(
            children: [
              // Brand header — the wordmark anchors the app and gives settings
              // its own home, so nothing sits on top of the chips.
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  ArulTokens.screenPadding,
                  6,
                  ArulTokens.screenPadding,
                  8,
                ),
                child: Row(
                  children: [
                    GopuramMark(
                      size: 20,
                      color: isDark ? ArulTokens.gold : ArulTokens.maroon,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Arul',
                      style: ArulTokens.screenTitle.copyWith(
                        fontSize: 20,
                        color: isDark ? ArulTokens.ivory : ArulTokens.lightText,
                      ),
                    ),
                    const Spacer(),
                    _GiftButton(onTap: () => context.push('/refer')),
                    const SizedBox(width: 8),
                    _SettingsButton(onTap: () => context.push('/settings')),
                  ],
                ),
              ),

              // Chips get the FULL width — nothing overlaps them, and a
              // frame-colored fade on the trailing edge shows the row scrolls
              // on past the last visible chip.
              Stack(
                children: [
                  feed is AsyncLoading
                      ? const FeedChipsSkeleton()
                      : const FeedChips(),
                  Positioned(
                    top: 0,
                    bottom: 0,
                    right: 0,
                    width: 24,
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.centerRight,
                            end: Alignment.centerLeft,
                            colors: [
                              frameColor,
                              frameColor.withValues(alpha: 0),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),

              // The header's floor: a full-width hairline the reel begins
              // directly beneath, so an outgoing card is clipped exactly at a
              // line the eye can see (see [_reelTopGap]). Same hairline tokens
              // as the frame's other quiet borders.
              Padding(
                padding: const EdgeInsets.only(
                  top: _chipsGap,
                  bottom: _reelTopGap,
                ),
                child: Container(
                  height: 1,
                  color: isDark
                      ? ArulTokens.cardBorderDark14
                      : ArulTokens.cardBorderLight,
                ),
              ),

              Expanded(
                // Offline wins over every catalog state (loading / cached data
                // / error): a clear "no internet" screen, never stale
                // wallpapers, never a hang. Retry re-checks connectivity AND
                // reloads the catalog, so it restores the moment the network is
                // back.
                child: offline
                    ? FeedError(
                        offline: true,
                        onRetry: () {
                          ref.invalidate(isOnlineProvider);
                          ref.invalidate(catalogProvider);
                        },
                      )
                    // One LayoutBuilder for the WHOLE feed zone, not just the
                    // reel: the skeleton and the reel must agree on the card's
                    // resting rect, or the card visibly resizes at the moment
                    // the first page lands.
                    : LayoutBuilder(
                        builder: (context, constraints) {
                          final geo = _geometryFor(
                            context,
                            constraints.maxHeight,
                          );
                          return switch (feed) {
                            AsyncLoading() => FeedLoading(
                              margin: geo.margin,
                              radius: _cardRadius,
                            ),

                            AsyncData(:final value) when value.isEmpty =>
                              FeedEmpty(
                                categoryLabel: _selectedLabel(),
                                onBrowseAll: () => ref
                                    .read(selectedCategoryProvider.notifier)
                                    .select(WallpaperCategory.allSlug),
                              ),

                            AsyncData(:final value) => _buildReel(
                              value,
                              geo,
                              constraints.maxHeight,
                            ),

                            AsyncError() => FeedError(
                              onRetry: () => ref.invalidate(catalogProvider),
                            ),
                          };
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _selectedLabel() {
    final slug = ref.read(selectedCategoryProvider);
    for (final c in ref.read(categoriesProvider)) {
      if (c.slug == slug) return c.label;
    }
    return '';
  }

  Widget _buildReel(List<Wallpaper> items, FeedCardGeometry geo, double h) {
    _syncFeed(items);

    final apply = ref.watch(wallpaperApplyProvider);
    final share = ref.watch(wallpaperShareProvider);
    final busy =
        apply is WallpaperApplyLoading || share is WallpaperSharePreparing;

    final m = geo.margin;

    // Distance from the REEL's bottom edge up to the card's — floor, then peek,
    // then the gap. Only the nudge and the end mark are screen-anchored, so they
    // are the only things that need it; forgetting the floor here would drop
    // both of them behind the pager. The nudge then sits just above the Apply
    // bar (a 16px gap over the bar's top), right over the verb it gates.
    final cardBottom = geo.floor + geo.peek + FeedCardGeometry.gap;
    final nudgeBottom = cardBottom + _CardChrome.actionBarTop + 16;

    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Stack(
      fit: StackFit.expand,
      children: [
        // End-of-collection mark. It lives BEHIND the pager, inside the
        // slot the next card's peek normally fills — so on every page but
        // the last it is covered by an actual wallpaper, and on the last it
        // owns what would otherwise be a dead void. Opacity is gated on the
        // index (onPageChanged fires at the halfway point of the swipe, so
        // it breathes in as the last card settles).
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: cardBottom,
          child: IgnorePointer(
            child: AnimatedOpacity(
              opacity: _index == items.length - 1 ? 1 : 0,
              duration: const Duration(milliseconds: 350),
              curve: Curves.easeOut,
              child: Center(child: _EndOfFeedMark(isDark: isDark)),
            ),
          ),
        ),

        // Media pager — one inset rounded card per page, top-aligned, with the
        // inter-card gap below it and the peek showing beneath that.
        // `padEnds: false` is what pins a snapped page flush to the top; the
        // fraction (see [_pagerFor]) decides how much of the following one stays
        // visible.
        //
        // The FLOOR is bottom padding on the pager, not part of it: the reel's
        // visible bottom edge sits above the system inset, so a card scrolling
        // away is clipped at a deliberate line rather than sliding off the
        // screen. Everything inside — card + gap + peek — fills exactly the
        // height that is left (`geo.pagerHeight`).
        //
        // Wrapped in a RefreshIndicator: on the first page a downward pull
        // has no previous page to reveal, so it overscrolls and refreshes
        // the whole catalog; on later pages the pull just navigates, so
        // refresh only fires "from the top", as intended.
        Padding(
          padding: EdgeInsets.only(bottom: geo.floor),
          child: RefreshIndicator(
            onRefresh: _refreshCatalog,
            color: ArulTokens.gold,
            backgroundColor: isDark ? ArulTokens.darkSurface : ArulTokens.ivory,
            child: PageView.builder(
              controller: _pagerFor(geo, geo.pagerHeight(h)),
              scrollDirection: Axis.vertical,
              padEnds: false,
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: items.length,
              onPageChanged: (i) {
                setState(() => _index = i);
                _video.onPageChanged(i);
                _precacheNextStatic(items, i);
                _onCardSettled(i, items[i]);
              },
              // Each page is a self-contained card: media, scrim, badge and the
              // two buttons, all clipped to the same rounded rect. The controls
              // therefore TRAVEL WITH their wallpaper — they slide in as it
              // arrives and slide out with it, instead of hanging in a fixed
              // layer the artwork passes behind.
              //
              // The gap is bottom padding on the PAGE, so the page extent the
              // pager solves for is card + gap and the snap geometry stays a
              // stock PageView's.
              itemBuilder: (context, i) => Padding(
                padding: m.copyWith(bottom: FeedCardGeometry.gap),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(_cardRadius),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      _ReelMedia(wallpaper: items[i], index: i),
                      _CardChrome(
                        wallpaper: items[i],
                        busy: busy,
                        onApply: () =>
                            _onAction(PremiumGateAction.apply, items[i]),
                        onShare: () =>
                            _onAction(PremiumGateAction.share, items[i]),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),

        // Gate nudge — floats above the meta, keyed so each tap replays the
        // rise.
        if (_nudge != null)
          Positioned(
            left: 0,
            right: 0,
            bottom: nudgeBottom,
            child: Center(
              child: PremiumNudge(
                key: ValueKey(_nudgeSeq),
                action: _nudge!,
                onTap: () {
                  final action = _nudge!;
                  setState(() => _nudge = null);
                  context.push('/premium?source=${action.source}');
                },
                onDismissed: () => setState(() => _nudge = null),
              ),
            ),
          ),

        // In-flight transfer bar for an apply/share download.
        if (apply is WallpaperApplyLoading || share is WallpaperSharePreparing)
          Positioned(
            top: 0,
            left: m.left,
            right: m.right,
            child: _TransferProgress(
              progress: switch ((apply, share)) {
                (
                  WallpaperApplyLoading(
                    stage: WallpaperApplyStage.downloading,
                    :final progress,
                  ),
                  _,
                ) =>
                  progress,
                (_, WallpaperSharePreparing(:final progress)) => progress,
                _ => null,
              },
            ),
          ),
      ],
    );
  }
}

/// The Refer & Earn entry on the feed's top bar — a bare gold gift that catches
/// the eye through motion, not glow: it rests for [_restBeat], then gives one
/// short shake (a few damped rotations, like a wrapped box being rattled) and
/// settles.
///
/// Transform/opacity only, per the design rules — no ShaderMask sweep (that is
/// an offscreen pass every frame, on the surface that also decodes video).
class _GiftButton extends StatefulWidget {
  const _GiftButton({required this.onTap});

  final VoidCallback onTap;

  @override
  State<_GiftButton> createState() => _GiftButtonState();
}

class _GiftButtonState extends State<_GiftButton>
    with SingleTickerProviderStateMixin {
  /// One shake every ~2.8s: long enough to read as an invitation, not a nag.
  static const _restBeat = Duration(milliseconds: 2800);
  static const _shake = Duration(milliseconds: 700);

  /// Peak tilt, radians (~16°), and the number of half-swings in one shake.
  static const _amplitude = 0.28;
  static const _swings = 4.0;

  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: _restBeat,
  )..repeat();

  /// The shake occupies the tail of each cycle; the rest of it is the pause.
  late final Animation<double> _t = CurvedAnimation(
    parent: _c,
    curve: Interval(
      1 - _shake.inMilliseconds / _restBeat.inMilliseconds,
      1,
      curve: Curves.linear,
    ),
  );

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = isDark ? ArulTokens.gold : ArulTokens.maroon;

    return Semantics(
      button: true,
      label: 'Refer and earn',
      child: GestureDetector(
        onTap: () {
          HapticFeedback.lightImpact();
          widget.onTap();
        },
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          width: 34,
          height: 34,
          child: AnimatedBuilder(
            animation: _t,
            builder: (context, child) {
              // A sine wobble that decays across the shake window, so it ends
              // dead-level instead of snapping back mid-swing.
              final decay = 1 - _t.value;
              final angle =
                  math.sin(_t.value * _swings * 2 * math.pi) *
                  _amplitude *
                  decay;
              return Transform.rotate(angle: angle, child: child);
            },
            child: Icon(Icons.card_giftcard_rounded, size: 22, color: accent),
          ),
        ),
      ),
    );
  }
}

/// The settings entry on the feed's top bar. Styled like an inactive surface
/// chip in the current theme so it reads as quiet chrome next to the category
/// pills rather than an accent.
class _SettingsButton extends StatelessWidget {
  const _SettingsButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Semantics(
      button: true,
      label: 'Settings',
      child: GestureDetector(
        onTap: () {
          HapticFeedback.lightImpact();
          onTap();
        },
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: isDark ? ArulTokens.cardBgDark05 : ArulTokens.cardBgLight,
            shape: BoxShape.circle,
            border: Border.all(
              color: isDark
                  ? ArulTokens.cardBorderDark14
                  : ArulTokens.cardBorderLight,
            ),
          ),
          child: Icon(
            Icons.settings_rounded,
            size: 19,
            color: isDark
                ? ArulTokens.ivory.withValues(alpha: 0.92)
                : ArulTokens.maroon,
          ),
        ),
      ),
    );
  }
}

/// Marks the end of a category's reel: the brand gopuram between two hairlines
/// that fade outward, centred in the slot where the next card would otherwise
/// peek. Deliberately quiet — a closing flourish, not a message — so the feed
/// ends the way a book does, and no localized copy is needed.
class _EndOfFeedMark extends StatelessWidget {
  const _EndOfFeedMark({required this.isDark});

  final bool isDark;

  @override
  Widget build(BuildContext context) {
    // Same accent split as the header's mark: gold on the dark frame, maroon on
    // ivory — muted further because this sits at the feed's quietest edge.
    final accent = isDark ? ArulTokens.gold : ArulTokens.maroon;

    Widget hairline(bool leading) => Container(
      width: 30,
      height: 1,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: leading ? Alignment.centerLeft : Alignment.centerRight,
          end: leading ? Alignment.centerRight : Alignment.centerLeft,
          colors: [accent.withValues(alpha: 0), accent.withValues(alpha: 0.4)],
        ),
      ),
    );

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        hairline(true),
        const SizedBox(width: 12),
        GopuramMark(size: 16, color: accent.withValues(alpha: 0.65)),
        const SizedBox(width: 12),
        hairline(false),
      ],
    );
  }
}

/// The media of one reel page. Watches the video pool so the page rebinds when
/// the pool reassigns a player to this index. Poster + texture come from the
/// reused [ViewerMedia].
class _ReelMedia extends ConsumerWidget {
  const _ReelMedia({required this.wallpaper, required this.index});

  final Wallpaper wallpaper;
  final int index;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(videoPreloadControllerProvider);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final slot = controller.slotForIndex(index);
        return ViewerMedia(wallpaper: wallpaper, slot: slot);
      },
    );
  }
}

/// Everything that belongs to ONE wallpaper, painted inside that wallpaper's
/// own card: the bottom scrim, the deity's name, and the Apply/Share buttons.
///
/// This lives in the page, not in a fixed layer above the pager. A screen-
/// anchored overlay reads like a windshield — the artwork slides past behind
/// controls that never move, and the name of the deity you are looking at has
/// to be swapped in at the right moment by hand (which is what made it lag
/// behind the swipe). Parented to the card, the controls simply ARE part of the
/// wallpaper: they arrive with it, leave with it, and can never describe the
/// wrong one. It also means no fade, no recede, no scroll-notification
/// bookkeeping — the PageView moves them for free.
class _CardChrome extends StatelessWidget {
  const _CardChrome({
    required this.wallpaper,
    required this.busy,
    required this.onApply,
    required this.onShare,
  });

  /// Scrim height, and the band the badge + buttons live in (Pakiza's
  /// `AppFeed.scrimHeight`).
  static const double stackHeight = FeedCardGeometry.scrimHeight;

  /// Inset of the action row from the card's left, right and bottom edges —
  /// Pakiza's `AppFeed.actionInset`, one number for all three.
  ///
  /// The row used to run edge to edge and lean on the Apply pill's own width to
  /// stay clear of the corners, which stopped being true the moment the card
  /// narrowed. Stating the gutter beats inferring it.
  static const double _barInset = FeedCardGeometry.actionInset;
  static const double _barInsetH = FeedCardGeometry.actionInset;

  /// Distance from the card's bottom edge up to the TOP of the action bar. The
  /// feed anchors the gate nudge just above this so it rises right over Apply,
  /// not stranded in the middle of the artwork.
  static const double actionBarTop = _barInset + _ActionBar.height;

  final Wallpaper wallpaper;
  final bool busy;
  final VoidCallback onApply;
  final VoidCallback onShare;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // IgnorePointer is LOAD-BEARING, not decoration: RenderDecoratedBox
        // overrides hitTestSelf and a BoxDecoration hit-tests true anywhere
        // inside its box. Painted above the media, the scrim would otherwise
        // swallow every touch in the bottom 190 — a swipe started down there
        // would never reach the PageView and the reel would not advance.
        const Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: stackHeight,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(gradient: ArulTokens.feedBottomScrim),
            ),
          ),
        ),

        Positioned(
          left: _barInsetH,
          right: _barInsetH,
          bottom: _barInset,
          child: _ActionBar(busy: busy, onApply: onApply, onShare: onShare),
        ),

        // Pointer-transparent: a DecoratedBox hit-tests true anywhere in its
        // box, so the LIVE pill would otherwise be a dead zone over the pager.
        // Anchored top-right, on the same gutter as the action row so the card's
        // chrome shares one edge.
        //
        // Inset from the CARD, not from the status bar. It used to add
        // `viewPadding.top`, left over from when the reel ran full-bleed under
        // the system bars; the card has sat below a header, a chips row and a
        // divider for a while now, so that was ~24dp of phantom offset pushing
        // the badge into the artwork.
        Positioned(
          top: 14,
          right: _barInsetH,
          child: IgnorePointer(child: _FeedMeta(wallpaper: wallpaper)),
        ),
      ],
    );
  }
}

/// The feed's action bar: a wide Apply pill with a circular Share beside it,
/// centred on the card's lower edge.
///
/// This replaces the old right-edge icon rail. The rail put the app's ONE
/// primary verb (Apply) in the same visual weight as Share, in the zone the
/// thumb uses to swipe — so the primary action both read as optional and shared
/// its hit area with the gesture that drives the feed. A centred pill states the
/// verb in words, sits where the thumb rests, and clears the swipe column.
///
/// Colour is deliberately NOT the design system's [ArulTokens.ctaGreen]: that
/// token is for CTAs on THEMED surfaces (sheets, premium, sign-in), where the
/// background is ours. Here the button sits directly on someone's artwork, and
/// the app's established over-media language is ivory + shadow (rail glyphs,
/// meta text, LIVE badge). So Apply is that language in pill form — solid ivory,
/// maroon label — and Share is its secondary weight: the same ivory, held as
/// glass. Hierarchy comes from fill and width, never from a hue that has to win
/// a fight with 428 devotional wallpapers.
class _ActionBar extends StatelessWidget {
  const _ActionBar({
    required this.busy,
    required this.onApply,
    required this.onShare,
  });

  /// Both buttons' height, and the row's — Pakiza's 52, so the pill and the
  /// circle sit on one baseline whatever the locale does to the label. Exported
  /// because the feed anchors the gate nudge off the bar's top edge.
  static const double height = 52;

  final bool busy;
  final VoidCallback onApply;
  final VoidCallback onShare;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Flexible(
          child: _ApplyPill(label: l10n.apply, onTap: busy ? null : onApply),
        ),
        const SizedBox(width: 12),
        _ShareCircle(label: l10n.share, onTap: busy ? null : onShare),
      ],
    );
  }
}

/// Primary: solid ivory, maroon label. Given a floor width so it reads as the
/// dominant action even where the localized verb is a single short word.
class _ApplyPill extends StatelessWidget {
  const _ApplyPill({required this.label, required this.onTap});

  final String label;

  /// Null while an apply/share is in flight — a second tap would start a second
  /// download racing the first.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null;
    return Semantics(
      button: true,
      enabled: !disabled,
      label: label,
      child: Opacity(
        opacity: disabled ? 0.55 : 1,
        child: Material(
          color: ArulTokens.ivory,
          borderRadius: BorderRadius.circular(ArulTokens.pillRadius),
          elevation: 0,
          child: InkWell(
            onTap: disabled
                ? null
                : () {
                    HapticFeedback.lightImpact();
                    onTap!();
                  },
            borderRadius: BorderRadius.circular(ArulTokens.pillRadius),
            splashColor: ArulTokens.maroonTintFill08,
            highlightColor: ArulTokens.maroonTintFill07,
            // No `alignment:` here — a Container with an alignment expands to
            // its max constraint, which is what stretched the pill across the
            // whole card. Without it the box hugs the label and the minWidth
            // does the rest, so the pill keeps a constant, reference-like width
            // whatever the locale's verb is.
            // The floor stops a one-word locale ("Set") collapsing the pill to a
            // chip; the ceiling stops the longer ones (ta/ml/te set "Apply" as a
            // whole word) stretching it across the card. Both fit the 329dp the
            // row has inside an 18dp-guttered card — pill + 12 + a 52 circle.
            child: Container(
              height: _ActionBar.height,
              constraints: const BoxConstraints(minWidth: 168, maxWidth: 240),
              padding: const EdgeInsets.symmetric(horizontal: 26),
              // Text only, like the reference: an icon would crowd the longer
              // verbs (ta/ml/te set "Apply" as a whole word) and this pill is
              // already the only thing that can be tapped down here.
              child: Center(
                widthFactor: 1,
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: ArulTokens.button.copyWith(
                    fontSize: 16,
                    color: ArulTokens.maroon,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Secondary: the same ivory held as glass — a translucent fill with a hairline
/// border, so it stays readable on white temples and night skies alike without
/// competing with the pill.
class _ShareCircle extends StatelessWidget {
  const _ShareCircle({required this.label, required this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null;
    return Semantics(
      button: true,
      enabled: !disabled,
      label: label,
      child: Opacity(
        opacity: disabled ? 0.55 : 1,
        child: Material(
          color: const Color.fromRGBO(250, 245, 236, 0.18),
          shape: const CircleBorder(
            side: BorderSide(color: Color.fromRGBO(250, 245, 236, 0.45)),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: disabled
                ? null
                : () {
                    HapticFeedback.lightImpact();
                    onTap!();
                  },
            child: const SizedBox(
              width: _ActionBar.height,
              height: _ActionBar.height,
              child: Icon(
                Icons.share_rounded,
                size: 21,
                color: ArulTokens.ivory,
                shadows: ArulTokens.railIconShadow,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Top-right meta: only the gold LIVE badge (live items). The category label and
/// the deity name were intentionally removed so the wallpaper stands on its own;
/// static cards render nothing here.
class _FeedMeta extends StatelessWidget {
  const _FeedMeta({required this.wallpaper});

  final Wallpaper wallpaper;

  @override
  Widget build(BuildContext context) {
    if (wallpaper.kind != WallpaperKind.live) return const SizedBox.shrink();
    // Sizes to its own label; the enclosing Positioned pins it top-right.
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: ArulTokens.gold,
        borderRadius: BorderRadius.circular(ArulTokens.liveBadgeRadius),
      ),
      child: const Text('LIVE', style: ArulTokens.liveBadge),
    );
  }
}

/// Hairline transfer bar across the top of the reel for an in-flight
/// apply/share. Null [progress] renders indeterminate (a bar parked at 0% reads
/// as stuck).
///
/// It carries no status-bar padding: the reel starts below the header, the chips
/// and the divider, so the `viewPadding.top` this used to add was a leftover
/// from the full-bleed layout and dropped the bar into the middle of the card's
/// top edge.
class _TransferProgress extends StatelessWidget {
  const _TransferProgress({required this.progress});

  final double? progress;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(gradient: ArulTokens.feedTopScrim),
      child: SizedBox(
        height: 3,
        child: LinearProgressIndicator(
          value: progress,
          minHeight: 3,
          backgroundColor: Colors.transparent,
          color: ArulTokens.gold,
        ),
      ),
    );
  }
}
