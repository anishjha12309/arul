import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/l10n/app_localizations.dart';
import '../../../app/theme/motion.dart';
import '../../../app/theme/tokens.dart';
import '../../../app/widgets/arul_browse_header.dart';
import '../../../app/widgets/arul_chip.dart';
import '../../../app/widgets/arul_icon_tap.dart';
import '../../../app/widgets/arul_line_icons.dart';
import '../../../app/widgets/arul_toast.dart';
import '../../../app/widgets/reel/feed_card_geometry.dart';
import '../../../app/widgets/reel/reel_card.dart';
import '../../../app/widgets/reel/video_preload_controller.dart';
import '../../../core/analytics/analytics_provider.dart';
import '../../../core/analytics/journey_stamps.dart';
import '../../../core/config/app_config.dart';
import '../../../core/connectivity/connectivity_provider.dart';
import '../../../core/deeplink/deep_link_target.dart';
import '../../../core/deeplink/install_referrer_service.dart';
import '../../../core/haptics/arul_haptics.dart';
import '../../../data/models/wallpaper.dart';
import '../../../theme/arul_tokens.dart';
import '../../premium/providers/entitlement_provider.dart';
import '../../wallpapers/presentation/feed_states.dart';
import '../domain/status_video.dart';
import '../providers/status_action_provider.dart';
import '../providers/status_providers.dart';
import 'status_preparing_card.dart';
import 'status_share_sheet.dart';

/// The two premium verbs on a status clip; [source] names the gate and the paywall's `source=`.
enum StatusVerb {
  share('status_share'),
  save('status_save');

  const StatusVerb(this.source);

  final String source;
}

/// The Status tab: devotional clips with music in the same reel the wallpaper feed uses.
class StatusScreen extends ConsumerStatefulWidget {
  const StatusScreen({super.key});

  @override
  ConsumerState<StatusScreen> createState() => _StatusScreenState();
}

class _StatusScreenState extends ConsumerState<StatusScreen>
    with SingleTickerProviderStateMixin {
  /// `viewportFraction` is final on PageController and needs the reel's measured height, exactly
  /// as the feed's pager -> built lazily in [_pagerFor].
  PageController? _pager;
  double? _pagerFraction;

  /// Captured in initState -> `ref` is unusable from dispose(), where the pool is detached.
  late final VideoPreloadController<StatusVideo> _video;

  int _index = 0;

  // A forward swipe folds the chips away so the card takes their height; back, or the first card,
  // brings them back. Decided on settle: a reel resized mid-drag would drop the drag.
  late final AnimationController _chipsReveal = AnimationController(
    vsync: this,
    value: 1,
  );
  int _settledIndex = 0;
  List<StatusVideo>? _served;
  int? _pendingIndex;

  bool _fetchingBehind = false;

  /// A swipe passing through is not engagement -> `status_engaged` fires after a 2 s dwell.
  Timer? _dwellTimer;
  static const _dwellThreshold = Duration(seconds: 2);

  @override
  void initState() {
    super.initState();
    _video = ref.read(statusVideoControllerProvider);
    // A status link landing on an already-built screen must re-run the build that consumes it.
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
    _pager?.dispose();
    _chipsReveal.dispose();
    _video.detach();
    super.dispose();
  }

  PageController _pagerFor(FeedCardGeometry geo, double height) {
    final fraction = height <= 0
        ? 1.0
        : (geo.pageExtent / height).clamp(0.2, 1.0);
    if (_pager != null && _pagerFraction == fraction) return _pager!;
    final previous = _pager;
    _pagerFraction = fraction;
    _pager = PageController(initialPage: _index, viewportFraction: fraction);
    if (previous != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => previous.dispose());
    }
    return _pager!;
  }

  void _onReelSettled() {
    final from = _settledIndex;
    _settledIndex = _index;
    if (_index == from && _index != 0) return;
    final reveal = _index == 0 || _index < from;
    final duration = context.reduceMotion ? Duration.zero : Motion.settle;
    unawaited(
      _chipsReveal.animateTo(
        reveal ? 1 : 0,
        duration: duration,
        curve: Motion.settleCurve,
      ),
    );
  }

  void _onCardSettled(StatusVideo status) {
    _dwellTimer?.cancel();
    _dwellTimer = Timer(_dwellThreshold, () {
      if (!mounted) return;
      ref
          .read(analyticsServiceProvider)
          .track(
            'status_engaged',
            properties: {'status_id': status.id, 'category': status.category},
          );
    });
  }

  /// Re-points the pager and the pool when the filtered list changes — chip switch, first data, link.
  void _sync(List<StatusVideo> items) {
    final previous = _served;
    if (previous != null &&
        _pendingIndex == null &&
        _sameIds(previous, items)) {
      _served = items;
      return;
    }
    _served = items;
    final pending = _pendingIndex;
    final target = pending != null && pending >= 0 && pending < items.length
        ? pending
        : 0;
    _pendingIndex = null;
    _index = target;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final pager = _pager;
      if (pager != null && pager.hasClients) pager.jumpToPage(target);
      _video
        ..reclaimDecoders()
        ..setItems(items, initialIndex: target)
        ..onPageChanged(target);
      if (target < items.length) _onCardSettled(items[target]);
    });
  }

  static bool _sameIds(List<StatusVideo> a, List<StatusVideo> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id) return false;
    }
    return true;
  }

  /// Opens the clip a share or ad link asked for, on All. A miss is silent — it may be unpublished.
  void _maybeOpenDeepLink(List<StatusVideo> all) {
    if (all.isEmpty) return;
    final target = ArulDeepLink.consumeStatus(
      shell: ArulShellScope.of(context),
    );
    if (target == null) return;
    unawaited(ref.read(installReferrerServiceProvider).clearPendingTarget());

    const allSlug = WallpaperCategory.allSlug;
    final index = statusFeedOrder(
      allSlug,
      all,
    ).indexWhere((s) => s.id == target.id);
    if (index < 0) return;
    ref
        .read(analyticsServiceProvider)
        .track('deep_link_opened', properties: target.analyticsProperties);
    // First data on All: the build that follows runs [_sync] -> the pager and the pool start ON the
    // target. A detour through card 0 opened its clip and staged card 1 against the one the link
    // asked for: three transfers for one card, 34-60 s on a slow 4G.
    if (_served == null &&
        ref.read(selectedStatusCategoryProvider) == allSlug) {
      _pendingIndex = index;
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        _pendingIndex = index;
        _served = null;
      });
      ref.read(selectedStatusCategoryProvider.notifier).select(allSlug);
    });
  }

  Future<bool> _isPremium() async {
    try {
      return await ref.read(entitlementProvider.future);
    } catch (_) {
      // A failed fetch gates closed -> the Worker's signed-url check stays authoritative.
      return false;
    }
  }

  Future<void> _onAction(StatusVerb verb, StatusVideo status) async {
    final premium = await _isPremium();
    if (!mounted) return;
    if (!premium) {
      _toPaywall(verb, status);
      return;
    }
    switch (verb) {
      case StatusVerb.share:
        await _doShare(status);
      case StatusVerb.save:
        await _doSave(status);
    }
  }

  void _toPaywall(StatusVerb verb, StatusVideo status) {
    ref
        .read(analyticsServiceProvider)
        .track(
          '${verb.source}_blocked_premium',
          properties: {'status_id': status.id, 'category': status.category},
        );
    JourneyStamps.noteGate(
      verb.source,
      category: status.category,
      itemId: status.id,
    );
    unawaited(context.push('/premium?source=${verb.source}'));
  }

  // Card -> the Arul sheet (or the system sheet without WhatsApp) -> the pick. Back on the card
  // or a closed sheet shares nothing and tracks nothing.
  Future<void> _doShare(StatusVideo status) async {
    final actions = ref.read(statusActionProvider.notifier);
    if (ref.read(statusActionProvider) is! StatusActionIdle) return;
    final prepared = actions.prepareShare(status);
    try {
      final stayed = await _whilePreparing(prepared);
      final prep = await prepared;
      if (!stayed || !mounted || prep == null) return;
      final StatusShareTarget? target;
      switch (prep) {
        case StatusShareSettled(:final outcome):
          _reportShare(outcome, status);
          return;
        case StatusShareReady(whatsApp: false):
          target = StatusShareTarget.more;
        case StatusShareReady():
          target = await StatusShareSheet.show(context);
      }
      if (target == null) return;
      final outcome = await actions.shareVia(target);
      if (mounted && outcome != null) _reportShare(outcome, status);
    } finally {
      // Every way out short of a pick — the card failing to open included — must not leave the
      // prepared clip holding the pills.
      await prepared;
      actions.dismissShare();
    }
  }

  // After Back the pills stay disabled until the fetch settles -> the reel's top hairline says why.
  Future<bool> _whilePreparing(Future<Object?> work) async {
    final stayed = await StatusPreparingCard.show(context, until: work);
    if (!stayed && mounted) {
      setState(() => _fetchingBehind = true);
      await work;
      if (mounted) setState(() => _fetchingBehind = false);
    }
    return stayed;
  }

  void _reportShare(StatusActionOutcome outcome, StatusVideo status) {
    final l10n = AppLocalizations.of(context);
    switch (outcome) {
      case StatusActionOutcome.done:
        break;
      case StatusActionOutcome.premiumRequired:
        _toPaywall(StatusVerb.share, status);
      case StatusActionOutcome.offline:
        showArulToast(context, l10n.offlineBody, kind: ToastKind.error);
      case StatusActionOutcome.permissionDenied:
      case StatusActionOutcome.failed:
        showArulToast(context, l10n.errorGeneric, kind: ToastKind.error);
    }
  }

  Future<void> _doSave(StatusVideo status) async {
    final l10n = AppLocalizations.of(context);
    if (ref.read(statusActionProvider) is! StatusActionIdle) return;
    final saving = ref.read(statusActionProvider.notifier).save(status);
    // Back only hides the card: the save carries on and its toast still lands.
    await _whilePreparing(saving);
    final outcome = await saving;
    if (!mounted || outcome == null) return;
    switch (outcome) {
      case StatusActionOutcome.done:
        showArulToast(context, l10n.statusSaved, kind: ToastKind.success);
      case StatusActionOutcome.premiumRequired:
        _toPaywall(StatusVerb.save, status);
      case StatusActionOutcome.offline:
        showArulToast(context, l10n.offlineBody, kind: ToastKind.error);
      case StatusActionOutcome.permissionDenied:
        showArulToast(
          context,
          l10n.statusPermissionDenied,
          kind: ToastKind.error,
        );
      case StatusActionOutcome.failed:
        showArulToast(context, l10n.statusSaveFailed, kind: ToastKind.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final frameColor = isDark ? ArulTokens.darkSurface : ArulTokens.ivory;

    if (ref.watch(statusCatalogProvider) case AsyncData(:final value)) {
      _maybeOpenDeepLink(value);
    }
    final feed = ref.watch(statusFeedProvider);
    // Kept warm so a gated tap reads a resolved value instead of a fresh /me round trip.
    ref.watch(entitlementProvider);
    // Offline with nothing loaded is the offline card, never a generic failure. With clips already
    // in hand the reel stays: cached clips still play, and a Share or Save says offline itself.
    final offline =
        !feed.hasValue && ref.watch(isOnlineProvider).value == false;

    return AnnotatedRegion<SystemUiOverlayStyle>(
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
              ArulBrowseHeader(
                title: l10n.statusTitle,
                chipsReveal: _chipsReveal,
                actions: [
                  ArulIconTap.glyph(
                    glyph: ArulLineGlyph.settings,
                    label: l10n.settingsTitle,
                    identifier: 'arul_header_settings',
                    onTap: () => context.push('/settings'),
                  ),
                ],
                chips: feed.hasValue
                    ? const StatusChips()
                    : const FeedChipsSkeleton(),
              ),
              Expanded(
                // One LayoutBuilder for loading AND reel -> the skeleton and the card share a rect.
                child: offline
                    ? FeedError(
                        offline: true,
                        body: l10n.offlineStatusBody,
                        retryIdentifier: 'arul_status_retry',
                        onRetry: () {
                          ref.invalidate(isOnlineProvider);
                          unawaited(
                            ref.read(statusCatalogProvider.notifier).refresh(),
                          );
                        },
                      )
                    : LayoutBuilder(
                        builder: (context, constraints) {
                          // The SLOT asks for the tallest clip shape; each card then sits in it at
                          // its own clip's shape, whole — never cut, never padded.
                          final geo = FeedCardGeometry.resolve(
                            context,
                            reelHeight: constraints.maxHeight,
                            askAspect: FeedCardGeometry.clipAspect,
                          );
                          return switch (feed) {
                            AsyncValue(:final value?) when value.isEmpty =>
                              FeedEmpty(
                                title: l10n.statusEmpty,
                                onBrowseAll: () => ref
                                    .read(
                                      selectedStatusCategoryProvider.notifier,
                                    )
                                    .select(WallpaperCategory.allSlug),
                              ),
                            AsyncValue(:final value?) => _buildReel(
                              value,
                              geo,
                              constraints.maxHeight,
                              l10n,
                            ),
                            AsyncError() => FeedError(
                              title: l10n.statusError,
                              retryIdentifier: 'arul_status_retry',
                              onRetry: () => unawaited(
                                ref
                                    .read(statusCatalogProvider.notifier)
                                    .refresh(),
                              ),
                            ),
                            _ => FeedLoading(
                              margin: geo.margin,
                              radius: FeedCardGeometry.radius,
                              body: l10n.statusLoadingBody,
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

  Widget _buildReel(
    List<StatusVideo> items,
    FeedCardGeometry geo,
    double h,
    AppLocalizations l10n,
  ) {
    _sync(items);
    final busy = ref.watch(
      statusActionProvider.select((s) => s is! StatusActionIdle),
    );
    final m = geo.margin;
    final cardBottom = geo.underhang + geo.peek + FeedCardGeometry.gap;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Stack(
      fit: StackFit.expand,
      children: [
        // Behind the pager, in the slot the next card's peek fills -> seen only on the last card.
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: cardBottom,
          child: IgnorePointer(
            child: AnimatedOpacity(
              opacity: _index == items.length - 1 ? 1 : 0,
              duration: context.reduceMotion ? Duration.zero : Motion.breathe,
              curve: Motion.settleCurve,
              child: Center(child: ReelEndMark(isDark: isDark)),
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.only(top: geo.headroom, bottom: geo.underhang),
          // A pull on the first card re-reads the catalog, exactly as the wallpaper reel's does;
          // on a later card the pull only pages back.
          child: RefreshIndicator(
            onRefresh: () {
              ArulHaptics.firm();
              return ref.read(statusCatalogProvider.notifier).refresh();
            },
            color: ArulTokens.gold,
            backgroundColor: isDark ? ArulTokens.darkSurface : ArulTokens.ivory,
            child: NotificationListener<ScrollEndNotification>(
              onNotification: (n) {
                if (n.depth == 0) _onReelSettled();
                return false;
              },
              child: PageView.builder(
                controller: _pagerFor(geo, geo.pagerHeight(h)),
                scrollDirection: Axis.vertical,
                padEnds: false,
                physics: const AlwaysScrollableScrollPhysics(),
                itemCount: items.length,
                onPageChanged: (i) {
                  setState(() => _index = i);
                  _video.onPageChanged(i);
                  _onCardSettled(items[i]);
                },
                itemBuilder: (context, i) => Padding(
                  padding: m.copyWith(bottom: FeedCardGeometry.gap),
                  // The card is the clip's own shape inside the slot (Shubh's rule): a 2:3 clip is
                  // shorter, a tall clip narrower, each centred under the chips with the slot's top.
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: SizedBox.fromSize(
                      size: FeedCardGeometry.contain(geo.size, items[i].aspect),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(
                          FeedCardGeometry.radius,
                        ),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            // Tap pauses and resumes; vertical drags still belong to the pager.
                            GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () {
                                ArulHaptics.tap();
                                _video.toggleHeldByUser();
                              },
                              child: ReelMedia(
                                controller: _video,
                                index: i,
                                builder: (context, slot) =>
                                    StatusMedia(status: items[i], slot: slot),
                              ),
                            ),
                            IgnorePointer(
                              child: _HeldMark(controller: _video, index: i),
                            ),
                            ReelCardChrome(
                              actions: ReelActionBar(
                                busy: busy,
                                primary: ReelAction(
                                  icon: Icons.send_rounded,
                                  image: const AssetImage(
                                    'assets/images/whatsapp.webp',
                                  ),
                                  label: l10n.statusWhatsapp,
                                  semanticsId: 'arul_status_whatsapp',
                                  onTap: () =>
                                      _onAction(StatusVerb.share, items[i]),
                                ),
                                secondary: ReelAction(
                                  icon: Icons.file_download_outlined,
                                  label: l10n.statusSave,
                                  semanticsId: 'arul_status_save',
                                  onTap: () =>
                                      _onAction(StatusVerb.save, items[i]),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        if (_fetchingBehind)
          Positioned(
            top: 0,
            left: m.left,
            right: m.right,
            child: const _StatusTransferProgress(),
          ),
      ],
    );
  }
}

/// A clip's page: poster mounted for the page's whole life, texture faded in on its first frame.
class StatusMedia extends StatelessWidget {
  const StatusMedia({super.key, required this.status, this.slot});

  final StatusVideo status;
  final LiveVideoSlot? slot;

  @override
  Widget build(BuildContext context) {
    final slot = this.slot;
    final width =
        (MediaQuery.sizeOf(context).width *
                MediaQuery.devicePixelRatioOf(context))
            .round();
    // The card IS the clip's shape (FeedCardGeometry.contain) -> fill is lossless: the whole
    // picture, edge to edge, nothing trimmed and nothing of ours beside it.
    return ColoredBox(
      color: ArulColors.ink,
      child: Stack(
        fit: StackFit.expand,
        children: [
          CachedNetworkImage(
            imageUrl: status.posterUrl(AppConfig.cdnBaseUrl),
            fit: BoxFit.fill,
            memCacheWidth: width,
            fadeInDuration: Duration.zero,
            // The loading card's sweep until the poster lands -> the card never reads as a void
            // with two buttons floating in it (ink on the ink frame is invisible).
            placeholder: (_, _) => const ReelPosterPlaceholder(),
            errorWidget: (_, _, _) => const SizedBox.shrink(),
          ),
          if (slot != null)
            ReelLiveTexture(
              slot: slot,
              alignment: Alignment.center,
              fit: BoxFit.fill,
            ),
        ],
      ),
    );
  }
}

/// The play mark over a card the user paused, or that lost the speaker to another app.
class _HeldMark extends StatelessWidget {
  const _HeldMark({required this.controller, required this.index});

  final VideoPreloadController<StatusVideo> controller;
  final int index;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (!controller.isHeld) return const SizedBox.shrink();
        return const Center(
          child: Icon(
            Icons.play_arrow_rounded,
            size: 64,
            color: ArulTokens.ivory,
            shadows: ArulTokens.railIconShadow,
          ),
        );
      },
    );
  }
}

class _StatusTransferProgress extends ConsumerWidget {
  const _StatusTransferProgress();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final progress = ref.watch(
      statusActionProvider.select(
        (s) => switch (s) {
          StatusActionBusy(:final progress) => progress,
          _ => null,
        },
      ),
    );
    return ReelTransferBar(progress: progress);
  }
}

/// The status chip row — the same control and the same strip as the feed's.
class StatusChips extends ConsumerWidget {
  const StatusChips({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final categories = ref.watch(statusCategoriesProvider);
    final selected = ref.watch(selectedStatusCategoryProvider);
    if (categories.isEmpty) return const SizedBox.shrink();
    final items = <WallpaperCategory>[
      WallpaperCategory(WallpaperCategory.allSlug, l10n.categoryAll),
      ...categories,
    ];
    return SizedBox(
      height: ArulChip.categoryStripHeight,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(
          horizontal: ArulTokens.screenPadding,
        ),
        itemCount: items.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final c = items[i];
          return ArulChip(
            label: c.label,
            selected: c.slug == selected,
            variant: ArulChipVariant.category,
            identifier: 'arul_status_chip_${c.slug}',
            onTap: () => ref
                .read(selectedStatusCategoryProvider.notifier)
                .select(c.slug),
          );
        },
      ),
    );
  }
}
