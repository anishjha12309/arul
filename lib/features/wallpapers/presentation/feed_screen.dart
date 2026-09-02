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
import '../../../core/deeplink/deep_link_target.dart';
import '../../../core/haptics/arul_haptics.dart';
import '../../../app/widgets/arul_browse_header.dart';
import '../../../app/widgets/arul_earn_button.dart';
import '../../../app/widgets/arul_toast.dart';
import '../../../app/widgets/gopuram_mark.dart';
import '../../../data/models/wallpaper.dart';
import '../../../theme/arul_tokens.dart';
import '../../premium/providers/entitlement_provider.dart';
import '../data/feed_video_player.dart';
import '../data/wallpaper_apply_service.dart';
import '../providers/catalog_providers.dart';
import '../providers/video_preload_provider.dart';
import '../providers/wallpaper_apply_provider.dart';
import '../providers/wallpaper_share_provider.dart';
import 'apply_restore.dart';
import 'apply_sheet.dart';
import 'feed_card_geometry.dart';
import 'feed_states.dart';
import 'live_mark.dart';
import 'premium_gate_action.dart';
import 'video_preload_controller.dart';
import 'viewer_media.dart';

/// The home surface: a Shorts-style vertical reel of wallpapers, one page each (Spec > Reel feed).
///
/// Chips ride the shared header; everything else is parented to the CARD, not the screen — see
/// [_CardChrome]. Browse and preview are free -> Apply and Share are premium-gated (CLAUDE.md §5).
class FeedScreen extends ConsumerStatefulWidget {
  const FeedScreen({super.key});

  @override
  ConsumerState<FeedScreen> createState() => _FeedScreenState();
}

class _FeedScreenState extends ConsumerState<FeedScreen>
    with ApplyRestore, WidgetsBindingObserver {
  /// `viewportFraction` is final on PageController and needs the reel's measured height -> build
  /// lazily in [_pagerFor], never in initState.
  ///
  /// With `padEnds: false` the fraction IS the page extent as a share of the viewport ->
  /// `pageExtent / height` pins a snapped page flush to the top and leaves the rest as the peek.
  /// Stock PageView throughout — snap, drag and fling geometry are untouched.
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
    // The outgoing controller is still attached to the PageView being replaced this frame ->
    // disposing it inline throws -> let the frame land, then dispose.
    if (previous != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => previous.dispose());
    }
    return _pager!;
  }

  /// `ref` is unusable from `dispose()` in Riverpod 3 -> a `ref.read` there silently fails and
  /// `detach()` never runs, leaving the pool populated -> capture the controller in initState.
  late final VideoPreloadController _video;

  /// Held from initState for the same reason as [_video] — the feed-session summary is flushed from
  /// `dispose()`, where `ref` is unusable.
  late final AnalyticsService _analytics;

  int _index = 0;

  // PostHog bills per EVENT, not per property -> one `feed_session_ended` carrying counts answers
  // depth/mix/length for a fraction of the volume -> never one PostHog event per card.
  // Per-card `wallpaper_engaged` still fires for GA4, which is free and unsampled.

  /// A swipe passing through is not engagement -> a card counts as engaged only after it dwells for
  /// [_dwellThreshold] -> reset the timer on every page change.
  Timer? _dwellTimer;
  static const _dwellThreshold = Duration(seconds: 2);

  int _engagedCount = 0;
  int _engagedLive = 0;
  int _maxDepth = 0;
  DateTime? _feedSessionStart;

  /// The filtered list currently handed to the pager + video pool.
  ///
  /// feedProvider re-emits a NEW identity on every catalogProvider change (revalidate, pull-refresh)
  /// -> an identity check reset the browse position on each -> compare by CONTENT (ordered ids).
  List<Wallpaper>? _servedList;

  /// The page to jump to after an apply-driven cold restart -> set by [restoreFeedTo] once the
  /// restored category's list lands, consumed by [_syncFeed].
  int? _pendingRestoreIndex;

  /// A loading snapshot must never bounce a premium user to the paywall -> AWAIT
  /// `entitlementProvider.future`, never read a snapshot (CLAUDE.md §5).
  /// A failed fetch gates closed -> the Worker's signed-url check stays authoritative either way.
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
    // StatefulShellRoute.indexedStack keeps this screen alive across tab switches -> dispose()
    // almost never runs -> backgrounding is the real end-of-session signal, so observe it.
    WidgetsBinding.instance.addObserver(this);

    // A cold CDN handshake was 1189ms of the 1499ms the paywall clip took to first frame; pooled it
    // reached 312ms -> pay DNS + TCP + TLS here so the clip does not.
    //
    // Must be POST-AUTH: warming on the splash fought Google's token mint and POST /auth/login for
    // the same pipe and made first login 7-8s (splash_screen.dart) -> warm here, signed in.
    // Not on the entitlement read either — it is lazy, and resolved 18s AFTER the paywall opened.
    //
    // ExoPlayer is on HttpURLConnection -> only the NATIVE pool is one it finds warm -> issue from
    // there. A pooled connection is per HOST -> the clip's language is irrelevant; any cut reuses it.
    unawaited(
      FeedVideoPlayerPool.warmConnection(
        '${AppConfig.cdnBaseUrl}/onboarding/en.mp4',
      ).catchError((_) {}),
    );

    // maybeOpenDeepLink runs from build() -> a target landing on an already-built screen (warm App
    // Link, deferred delivery) would never re-run it, least of all parked offstage -> rebuild here.
    ArulDeepLink.changes.addListener(_onDeepLinkChanged);
  }

  void _onDeepLinkChanged() {
    scheduleMicrotask(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _dwellTimer?.cancel();
    ArulDeepLink.changes.removeListener(_onDeepLinkChanged);
    WidgetsBinding.instance.removeObserver(this);
    // Backstop for the rare teardown that happens without a backgrounding first.
    _flushFeedSession();
    _pager?.dispose();
    // The controller is app-scoped -> disposing here races the Android 12+ Activity recreate an
    // apply can trigger -> never dispose it, detach().
    // detach() returns the decoders AND clears the list -> a later background/resume cannot spin
    // the pool up behind a screen with no video.
    _video.detach();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // `paused` (and `hidden`) is the last callback guaranteed before the process can be killed ->
    // it is the only reliable place to close out a feed session.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _flushFeedSession();
    } else if (state == AppLifecycleState.resumed) {
      // Foregrounding starts a NEW session, never resumes the closed one -> `seconds` stays real.
      _feedSessionStart = DateTime.now();
    }
  }

  /// Emits one `feed_session_ended` summary and resets the counters.
  ///
  /// Silent when no card was ever dwelled on -> opening the tab and leaving is not a session.
  /// Resetting after the emit -> safe to call repeatedly across background/foreground, no doubles.
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

  /// Starts the dwell clock for the card that just landed -> fires per-card `wallpaper_engaged`
  /// (GA4-only, not on the PostHog allow-list) and folds it into `feed_session_ended`'s counters.
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
          // Spelled as `wallpaper_shared`/`wallpaper_applied` spell it -> the engagement→apply
          // funnel joins on one key.
          'type': wallpaper.kind.name,
        },
      );
    });
  }

  /// Re-point the pager + video pool at [items] whenever the filtered list changes — category
  /// switch, first data, or an apply-restore jump.
  void _syncFeed(List<Wallpaper> items) {
    final previous = _servedList;

    // A revalidate or pull-refresh returning EQUIVALENT content re-emits a new list identity ->
    // detecting change by identity reset _index, jumped the pager and re-pointed the pool
    // mid-browse -> on unchanged items keep the user where they are.
    // Still hand the pool the fresh objects -> a same-id item whose URL changed re-opens (reconcile
    // is a no-op otherwise, so no flicker).
    // Never take this path with an apply-restore pending -> that jump must still land on its index.
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
      // The pool may hold no decoders (released by a prior apply) -> reclaim first; the index goes
      // in WITH the list so the pool opens the right clip first.
      _video
        ..reclaimDecoders()
        ..setWallpapers(items, initialIndex: target)
        ..onPageChanged(target);
      // onPageChanged only fires on a swipe -> the first card of a session, the one guaranteed to
      // be seen, would never count as engaged -> start its dwell clock here.
      if (target < items.length) _onCardSettled(target, items[target]);
    });
  }

  /// Whether two filtered feeds hold the same items in the same order (by id) -> a category switch
  /// or a rebuild that added/removed/reordered changes this; a re-fetch of the same catalog does not.
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
    jumpFeedTo(index: index);
    if (!wasLive) {
      showArulToast(
        context,
        AppLocalizations.of(context).applied,
        kind: ToastKind.success,
      );
    }
  }

  @override
  void jumpFeedTo({required int index}) {
    // The mixin already selected the category -> its list recompute drives _syncFeed -> that lands
    // on this index.
    setState(() => _pendingRestoreIndex = index);
  }

  /// Pull-to-refresh: an authoritative network reload, cascading to feedProvider.
  ///
  /// A bare invalidate re-emits the disk snapshot instantly and settles the indicator with no fresh
  /// data -> `refresh()` re-reads the version pointer and BYPASSES the serve-cached-first path.
  /// Never throws -> a failure with data on screen keeps the current feed; AsyncError renders retry
  /// only when there is nothing to show.
  Future<void> _refreshCatalog() =>
      ref.read(catalogProvider.notifier).refresh();

  /// Warms the NEXT item's full image when it is static -> a static→static swipe paints from cache
  /// instead of showing only the poster for the whole download.
  ///
  /// Live items are prefetched as bytes by the prefetch service's data window, not here.
  /// Same URL AND decode width as [ViewerMedia]'s full-resolution layer -> this precache and the
  /// page's render share ONE image-cache entry.
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
      // Never throw into the framework -> the render path keeps its own self-healing retry anyway.
      onError: (_, _) {},
    );
  }

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
    // A gated tap is already an intent to act, and only the premium SCREEN can satisfy it (owner's
    // call) -> track the blocked verb, then push STRAIGHT to /premium — every gated verb behaves
    // like `ensurePremium`. Never re-introduce a nudge, teaser sheet or interstitial here.
    // The wallpaper is attributed on the blocked event (docs/edge-cases.md).
    ref
        .read(analyticsServiceProvider)
        .track(
          '${action.source}_blocked_premium',
          properties: {'wallpaper_id': w.id, 'category': w.category},
        );
    unawaited(context.push('/premium?source=${action.source}'));
  }

  Future<void> _doApply(Wallpaper w) async {
    final l10n = AppLocalizations.of(context);

    // Android's live-wallpaper chooser asks Home/Lock/Both itself and decides -> live skips our
    // target sheet.
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
          // The wallpaper engine / chooser preview needs the hardware decoders the feed holds ->
          // a budget SoC has only a handful -> release them for the duration.
          releaseVideoDecoders: _video.releaseDecoders,
        );

    if (!mounted) return;
    final state = ref.read(wallpaperApplyProvider);
    switch (state) {
      case WallpaperApplySuccess(:final staticFallback):
        // A live Success can only be the static fallback (a normal live apply
        // ends Idle with the chooser open), and it needs its own line: the user
        // asked for motion and got a still, so "Wallpaper applied" alone would
        // read as the video being broken.
        showArulToast(
          context,
          staticFallback ? l10n.appliedLiveFallback : l10n.applied,
          kind: ToastKind.success,
        );
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
            kind: ToastKind.error,
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
          kind: ToastKind.error,
        );
      }
      ref.read(wallpaperShareProvider.notifier).reset();
    }
  }

  // ─── Build ───────────────────────────────────────────────────────────────────

  // The chips gap and the gap below the hairline now live in
  // [ArulBrowseHeader], which both browse tabs share — the reel's card is still
  // solved from whatever height that frame leaves, so its 1:1.86 ratio holds by
  // construction (see [FeedCardGeometry.resolve]).

  static const _cardRadius = FeedCardGeometry.radius;

  /// The card's resting geometry for a reel [height] — see [FeedCardGeometry].
  FeedCardGeometry _geometryFor(BuildContext context, double height) =>
      FeedCardGeometry.resolve(context, reelHeight: height);

  @override
  Widget build(BuildContext context) {
    // Restore after an apply-driven cold restart, and open any wallpaper a share
    // or ad link asked for — both once the full catalog is in, since both turn a
    // saved reference into a page index in the list this feed serves.
    if (ref.watch(catalogProvider) case AsyncData(:final value)) {
      maybeRestoreAfterApply(value);
      maybeOpenDeepLink(value);
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
              // Brand header — the wordmark anchors the app, so nothing sits on
              // top of the chips. Shared with the other two tabs
              // ([ArulScreenHeader]); its metrics are the ones the reel
              // geometry below is solved against, so they did not move when the
              // three headers were unified.
              //
              // Earn is the ONLY action up here. Settings used to sit beside it
              // and no longer does: it is a dock branch with its own permanent
              // tab, so a second entry in the corner was a duplicate control —
              // and it made this header the one that differed from Ringtones'
              // across the cross-fade.
              ArulBrowseHeader(
                title: 'Arul',
                // The WORDMARK, not a page title — bigger than Ringtones' and
                // Settings' labels and sat a touch lower in the band, because
                // it is the brand rather than a name for this screen. The other
                // two tabs deliberately do NOT take these.
                titleStyle: ArulTokens.wordmarkHeader,
                titleDrop: 1.5,
                actions: [ArulEarnButton(onTap: () => context.push('/refer'))],
                chips: feed is AsyncLoading
                    ? const FeedChipsSkeleton()
                    : const FeedChips(),
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

    // Distance from the REEL's bottom edge up to the card's — underhang, then
    // peek, then the gap. The end mark is the only screen-anchored thing left,
    // so it is the only one that needs it; forgetting it here would drop it
    // behind the pager.
    //
    // `underhang`, NOT the whole floor: half of it now sits above the card so
    // the reel is centred, and measuring from the bottom with the full floor
    // would put it half a floor too high.
    final cardBottom = geo.underhang + geo.peek + FeedCardGeometry.gap;

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
        // The FLOOR is padding around the pager, not part of it: the reel's
        // visible bottom edge sits above the system inset, so a card scrolling
        // away is clipped at a deliberate line rather than sliding off the
        // screen. Everything inside — card + gap + peek — fills exactly the
        // height that is left (`geo.pagerHeight`), which is why splitting the
        // floor across top and bottom recentres the reel without resizing
        // anything in it.
        //
        // Wrapped in a RefreshIndicator: on the first page a downward pull
        // has no previous page to reveal, so it overscrolls and refreshes
        // the whole catalog; on later pages the pull just navigates, so
        // refresh only fires "from the top", as intended.
        Padding(
          padding: EdgeInsets.only(top: geo.headroom, bottom: geo.underhang),
          child: RefreshIndicator(
            // Fires when the pull actually commits, not on every drag pixel.
            onRefresh: () {
              ArulHaptics.firm();
              return _refreshCatalog();
            },
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

  /// Inset of the live mark from the card's top and right edges.
  ///
  /// NOT [_barInsetH]. The action row can sit on 14 because it runs the width
  /// of the card and reads as a bar; a lone 24dp disc at 14 reads as jammed
  /// into the corner, because [FeedCardGeometry.radius] (24) is curving away
  /// directly behind it. 22 puts the disc's outer edge clear of that arc, so it
  /// sits ON the wallpaper rather than on its rim — while staying far enough in
  /// from the centre that it never lands on a face or a crown.
  static const double _liveMarkInset = 22;

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

        // The live marker, and the ONLY thing in the card's upper field.
        //
        // A gold "LIVE" text pill sat here until 2026-08-11; it read as a
        // warning on half the catalog and was untranslated English in a
        // six-language app. [LiveMark] replaces it with the Share circle's own
        // glass recipe at half scale — nothing to localize.
        //
        // Deliberately NOT on the action row's 14dp gutter (owner's call): at
        // that inset the mark rides the rim, and the card's 26dp corner radius
        // curves away right behind it, so it reads as stuck to the edge rather
        // than placed on the wallpaper. [_liveMarkInset] clears the corner arc
        // entirely and sits the mark inside the artwork's own field.
        //
        // Pointer-transparent for the same reason the pill was: a DecoratedBox
        // hit-tests true anywhere in its box, so without this the mark would be
        // a dead zone over the pager.
        //
        // Inset from the CARD, not the status bar — the reel has sat below a
        // header and a chips row for a while, so a `viewPadding.top` here would
        // be ~24dp of phantom offset pushing the mark into the artwork.
        if (wallpaper.kind == WallpaperKind.live)
          const Positioned(
            top: _liveMarkInset,
            right: _liveMarkInset,
            child: IgnorePointer(child: LiveMark()),
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
/// a fight with several hundred devotional wallpapers.
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
            // Apply is one of the feed's two commit verbs, so it presses firmer
            // than ordinary chrome. The outcome beat comes separately, from the
            // toast that reports what happened.
            onTapDown: disabled ? null : (_) => ArulHaptics.firm(),
            onTap: disabled ? null : onTap,
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
          // The over-media glass recipe, shared with [LiveMark] so the card's
          // two glass objects cannot drift apart. This one needs no shadow: it
          // sits inside the bottom scrim, which supplies its contrast.
          color: ArulTokens.overMediaGlassFill,
          shape: const CircleBorder(
            side: BorderSide(color: ArulTokens.overMediaGlassBorder),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            // Share is the other commit verb — same weight as Apply.
            onTapDown: disabled ? null : (_) => ArulHaptics.firm(),
            onTap: disabled ? null : onTap,
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
