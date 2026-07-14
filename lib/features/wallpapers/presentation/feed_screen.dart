import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/l10n/app_localizations.dart';
import '../../../app/widgets/arul_toast.dart';
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

  /// Snapshot gate for the tap handler. CLAUDE.md §5's real gate must `await
  /// entitlementProvider.future` (a loading snapshot must never bounce a
  /// premium user) — done properly when the purchase flow lands (phase-4);
  /// today the provider is hardcoded false, so the read never races.
  bool get _premium => ref.read(entitlementProvider).value ?? false;

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

  void _onAction(PremiumGateAction action, Wallpaper w) {
    if (_premium) {
      switch (action) {
        case PremiumGateAction.apply:
          _doApply(w);
        case PremiumGateAction.share:
          _doShare(w);
      }
      return;
    }
    // Free user: nudge once, then the sheet.
    // TODO(phase-4): track '${action.source}_blocked_premium'.
    if (!_nudgeShown) {
      setState(() {
        _nudgeShown = true;
        _nudge = action;
        _nudgeSeq++;
      });
    } else {
      PremiumSheet.show(context, source: action.source);
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

  @override
  Widget build(BuildContext context) {
    // Restore after an apply-driven cold restart, once the full catalog is in.
    if (ref.watch(catalogProvider) case AsyncData(:final value)) {
      maybeRestoreAfterApply(value);
    }

    final feed = ref.watch(feedProvider);

    return AnnotatedRegion<SystemUiOverlayStyle>(
      // Over full-bleed media the status/nav icons must be light in both themes.
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.light,
        systemNavigationBarContrastEnforced: false,
      ),
      child: Scaffold(
        backgroundColor: ArulTokens.darkSurface,
        body: switch (feed) {
          AsyncLoading() => const FeedLoading(),

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

    final topInset = MediaQuery.viewPaddingOf(context).top;
    final current = items[_index.clamp(0, items.length - 1)];

    return Stack(
      fit: StackFit.expand,
      children: [
        // Media pager — only the wallpaper per page; chrome is one layer above.
        NotificationListener<ScrollNotification>(
          onNotification: _onScroll,
          child: PageView.builder(
            controller: _pager,
            scrollDirection: Axis.vertical,
            itemCount: items.length,
            onPageChanged: (i) {
              setState(() => _index = i);
              _video.onPageChanged(i);
            },
            itemBuilder: (context, i) =>
                _ReelMedia(wallpaper: items[i], index: i),
          ),
        ),

        // Chrome layer: scrims + chips + action rail + meta, faded as one.
        IgnorePointer(
          ignoring: !_chromeVisible,
          child: AnimatedOpacity(
            opacity: _chromeVisible ? 1 : 0,
            duration: _chromeDuration,
            curve: ArulTokens.settleCurve,
            child: Stack(
              fit: StackFit.expand,
              children: [
                const Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  height: 130,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: ArulTokens.feedTopScrim,
                    ),
                  ),
                ),
                const Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  height: 190,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: ArulTokens.feedBottomScrim,
                    ),
                  ),
                ),

                Positioned(
                  top: topInset + 14,
                  left: 0,
                  right: 0,
                  child: const FeedChips(),
                ),

                Positioned(
                  right: 10,
                  bottom: 118,
                  child: _ActionRail(
                    busy: busy,
                    onApply: () => _onAction(PremiumGateAction.apply, current),
                    onShare: () => _onAction(PremiumGateAction.share, current),
                  ),
                ),

                Positioned(
                  left: 16,
                  right: 76,
                  bottom: 26,
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
            // Just above the meta block (meta bottom:26 + ~2 text lines + gap),
            // per README "floating nudge pill above meta".
            bottom: 110,
            child: Center(
              child: PremiumNudge(
                key: ValueKey(_nudgeSeq),
                action: _nudge!,
                onDismissed: () => setState(() => _nudge = null),
              ),
            ),
          ),

        // In-flight transfer bar for an apply/share download.
        if (apply is WallpaperApplyLoading || share is WallpaperSharePreparing)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
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
                shadows: ArulTokens.overMediaShadow,
              ),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 10.5,
                  color: ArulTokens.ivory.withValues(alpha: 0.85),
                  shadows: ArulTokens.overMediaShadow,
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
