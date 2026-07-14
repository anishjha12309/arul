import 'dart:math' as math;

import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/l10n/app_localizations.dart';
import '../../../core/analytics/analytics_provider.dart';
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
import 'feed_states.dart';
import 'premium_nudge.dart';
import 'video_preload_controller.dart';
import 'viewer_media.dart';

/// The home surface: a Shorts-style vertical reel of wallpapers, one full-bleed
/// page each (README > Reel feed). The old grid + separate viewer are gone —
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

class _FeedScreenState extends ConsumerState<FeedScreen> with ApplyRestore {
  late final PageController _pager;

  /// Captured in initState, NOT read lazily via `ref.read`: `ref` is unusable
  /// from `dispose()` in Riverpod 3, so a `ref.read` there silently fails to
  /// reach the controller — exactly how `detach()` never runs and the pool keeps
  /// a populated list after the feed closes. Hold the reference.
  late final VideoPreloadController _video;

  int _index = 0;

  /// The filtered list currently handed to the pager + video pool. Identity is
  /// stable until the category or catalog changes; a change triggers a resync.
  List<Wallpaper>? _servedList;

  /// Set by [restoreFeedTo] after an apply-driven cold restart: the page to jump
  /// to once the restored category's list lands. Consumed by [_syncFeed].
  int? _pendingRestoreIndex;

  /// Chrome (chips + action rail + meta) fades out while swiping, back on
  /// settle. Opacity only — never a relayout, never a blur.
  bool _chromeVisible = true;
  Duration _chromeDuration = ArulTokens.chromeSettleIn;

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
    _pager = PageController();
  }

  @override
  void dispose() {
    _pager.dispose();
    // Do NOT dispose the controller — it is app-scoped, and disposing here would
    // race the Android 12+ Activity recreate a wallpaper apply can trigger.
    // detach() returns the decoders AND clears the list so a later
    // background/resume cannot spin the pool up behind a screen with no video.
    _video.detach();
    super.dispose();
  }

  // ─── List sync ─────────────────────────────────────────────────────────────

  /// Re-point the pager + video pool at [items] whenever the filtered list
  /// changes (category switch, first data, or an apply-restore jump).
  void _syncFeed(List<Wallpaper> items) {
    if (identical(items, _servedList)) return;
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
      if (_pager.hasClients) _pager.jumpToPage(target);
      // reclaim: the pool may hold no decoders (released by a prior apply); the
      // index goes in WITH the list so the pool opens the right clip first.
      _video
        ..reclaimDecoders()
        ..setWallpapers(items, initialIndex: target)
        ..onPageChanged(target);
    });
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

  // ─── Chrome recede ───────────────────────────────────────────────────────────

  bool _onScroll(ScrollNotification n) {
    if (n is ScrollStartNotification) {
      _setChrome(false);
    } else if (n is ScrollEndNotification) {
      _setChrome(true);
    }
    return false;
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

  void _setChrome(bool visible) {
    if (_chromeVisible == visible) return;
    setState(() {
      _chromeVisible = visible;
      _chromeDuration = visible
          ? ArulTokens.chromeSettleIn
          : ArulTokens.chromeRecedeOut;
    });
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
      case WallpaperApplyError(:final isNetwork):
        showArulToast(
          context,
          isNetwork ? l10n.offlineBody : l10n.errorGeneric,
        );
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
        .share(w, message: l10n.shareMessage);

    if (!mounted) return;
    final state = ref.read(wallpaperShareProvider);
    if (state is WallpaperShareError) {
      showArulToast(
        context,
        state.isNetwork ? l10n.offlineBody : l10n.errorGeneric,
      );
      ref.read(wallpaperShareProvider.notifier).reset();
    }
  }

  // ─── Build ───────────────────────────────────────────────────────────────────

  /// The inset around the wallpaper card. The surrounding themed frame (ink in
  /// dark, ivory in light) is what keeps the chips row and settings entry
  /// legible over any artwork.
  static const _cardMargin = EdgeInsets.fromLTRB(12, 8, 12, 12);
  static const _cardRadius = 22.0;

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
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Stack(
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
                    : switch (feed) {
                        AsyncLoading() => const FeedLoading(
                          margin: _cardMargin,
                          radius: _cardRadius,
                        ),

                        AsyncData(:final value) when value.isEmpty => FeedEmpty(
                          categoryLabel: _selectedLabel(),
                          onBrowseAll: () => ref
                              .read(selectedCategoryProvider.notifier)
                              .select(WallpaperCategory.allSlug),
                        ),

                        AsyncData(:final value) => _buildReel(value),

                        AsyncError() => FeedError(
                          onRetry: () => ref.invalidate(catalogProvider),
                        ),
                      },
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

  Widget _buildReel(List<Wallpaper> items) {
    _syncFeed(items);

    final apply = ref.watch(wallpaperApplyProvider);
    final share = ref.watch(wallpaperShareProvider);
    final busy =
        apply is WallpaperApplyLoading || share is WallpaperSharePreparing;

    final current = items[_index.clamp(0, items.length - 1)];

    // Everything below is positioned against the wallpaper CARD, not the
    // screen: the card's margins are constant, so card-relative offsets are
    // margin + inner offset.
    const m = _cardMargin;

    return Stack(
      fit: StackFit.expand,
      children: [
        // Media pager — one inset rounded card per page. The padding lives
        // INSIDE the page so the snap/drag geometry is unchanged. Wrapped in a
        // RefreshIndicator: on the first page a downward pull has no previous
        // page to reveal, so it overscrolls and refreshes the whole catalog;
        // on later pages the pull just navigates, so refresh only fires "from
        // the top", as intended.
        RefreshIndicator(
          onRefresh: _refreshCatalog,
          color: ArulTokens.gold,
          backgroundColor: Theme.of(context).brightness == Brightness.dark
              ? ArulTokens.darkSurface
              : ArulTokens.ivory,
          child: NotificationListener<ScrollNotification>(
            onNotification: _onScroll,
            child: PageView.builder(
              controller: _pager,
              scrollDirection: Axis.vertical,
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: items.length,
              onPageChanged: (i) {
                setState(() => _index = i);
                _video.onPageChanged(i);
                _precacheNextStatic(items, i);
              },
              itemBuilder: (context, i) => Padding(
                padding: m,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(_cardRadius),
                  child: _ReelMedia(wallpaper: items[i], index: i),
                ),
              ),
            ),
          ),
        ),

        // Chrome layer: scrim + action rail + meta, faded as one. Chips and
        // settings live on the frame above and never recede.
        IgnorePointer(
          ignoring: !_chromeVisible,
          child: AnimatedOpacity(
            opacity: _chromeVisible ? 1 : 0,
            duration: _chromeDuration,
            curve: ArulTokens.settleCurve,
            child: Stack(
              fit: StackFit.expand,
              children: [
                // Bottom scrim, clipped to the card's lower corners so it
                // never paints on the frame.
                Positioned(
                  bottom: m.bottom,
                  left: m.left,
                  right: m.right,
                  height: 190,
                  child: const ClipRRect(
                    borderRadius: BorderRadius.only(
                      bottomLeft: Radius.circular(_cardRadius),
                      bottomRight: Radius.circular(_cardRadius),
                    ),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: ArulTokens.feedBottomScrim,
                      ),
                    ),
                  ),
                ),

                Positioned(
                  right: m.right + 10,
                  bottom: m.bottom + 92,
                  child: _ActionRail(
                    busy: busy,
                    onApply: () => _onAction(PremiumGateAction.apply, current),
                    onShare: () => _onAction(PremiumGateAction.share, current),
                  ),
                ),

                Positioned(
                  left: m.left + 16,
                  right: m.right + 64,
                  bottom: m.bottom + 20,
                  child: _FeedMeta(wallpaper: current),
                ),
              ],
            ),
          ),
        ),

        // Gate nudge — floats above the meta, keyed so each tap replays the rise.
        if (_nudge != null)
          Positioned(
            left: 0,
            right: 0,
            // Just above the meta block, per README "floating nudge pill
            // above meta".
            bottom: m.bottom + 104,
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

/// Right-edge action rail (README > Reel feed): Apply (`wallpaper` 30px) + Share
/// (`share` 28px) ONLY. Icon + 10.5px label, ivory, text-shadow. No like button.
class _ActionRail extends StatelessWidget {
  const _ActionRail({
    required this.busy,
    required this.onApply,
    required this.onShare,
  });

  final bool busy;
  final VoidCallback onApply;
  final VoidCallback onShare;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _RailButton(
          icon: Icons.wallpaper_rounded,
          iconSize: 30,
          label: 'Apply',
          onTap: busy ? null : onApply,
        ),
        const SizedBox(height: 22),
        _RailButton(
          icon: Icons.share_rounded,
          iconSize: 28,
          label: 'Share',
          onTap: busy ? null : onShare,
        ),
      ],
    );
  }
}

class _RailButton extends StatelessWidget {
  const _RailButton({
    required this.icon,
    required this.iconSize,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final double iconSize;
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
      child: GestureDetector(
        onTap: disabled
            ? null
            : () {
                HapticFeedback.lightImpact();
                onTap!();
              },
        behavior: HitTestBehavior.opaque,
        child: Opacity(
          opacity: disabled ? 0.5 : 1,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: iconSize,
                color: ArulTokens.ivory,
                shadows: ArulTokens.railIconShadow,
              ),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                  color: ArulTokens.ivory,
                  shadows: ArulTokens.railIconShadow,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Bottom-left meta (README > Reel feed): LIVE badge (live only) + category
/// 12.5px ivory-75%; title 17px/600 ivory.
class _FeedMeta extends StatelessWidget {
  const _FeedMeta({required this.wallpaper});

  final Wallpaper wallpaper;

  @override
  Widget build(BuildContext context) {
    // The title only earns its pixels when it says more than the category (many
    // items fall back title == categoryLabel).
    final titleAddsSomething =
        wallpaper.title.trim().toLowerCase() !=
        wallpaper.categoryLabel.trim().toLowerCase();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (wallpaper.kind == WallpaperKind.live) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: ArulTokens.gold,
                  borderRadius: BorderRadius.circular(
                    ArulTokens.liveBadgeRadius,
                  ),
                ),
                child: const Text('LIVE', style: ArulTokens.liveBadge),
              ),
              const SizedBox(width: 8),
            ],
            Flexible(
              child: Text(
                wallpaper.categoryLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ArulTokens.rowSub.copyWith(
                  color: ArulTokens.ivory.withValues(alpha: 0.75),
                  shadows: ArulTokens.overMediaShadow,
                ),
              ),
            ),
          ],
        ),
        if (titleAddsSomething) ...[
          const SizedBox(height: 6),
          Text(
            wallpaper.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: ArulTokens.sheetTitle.copyWith(
              color: ArulTokens.ivory,
              shadows: ArulTokens.overMediaShadow,
            ),
          ),
        ],
      ],
    );
  }
}

/// Hairline transfer bar under the status bar for an in-flight apply/share.
/// Null [progress] renders indeterminate (a bar parked at 0% reads as stuck).
class _TransferProgress extends StatelessWidget {
  const _TransferProgress({required this.progress});

  final double? progress;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(top: MediaQuery.viewPaddingOf(context).top),
      child: DecoratedBox(
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
      ),
    );
  }
}
