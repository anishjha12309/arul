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
import '../../../app/widgets/state_views.dart';
import '../../../core/analytics/analytics_provider.dart';
import '../../../core/analytics/journey_stamps.dart';
import '../../../core/config/app_config.dart';
import '../../../core/deeplink/deep_link_target.dart';
import '../../../core/deeplink/install_referrer_service.dart';
import '../../../data/models/wallpaper.dart';
import '../../../theme/arul_tokens.dart';
import '../../premium/providers/entitlement_provider.dart';
import '../../wallpapers/presentation/feed_states.dart';
import '../domain/status_video.dart';
import '../providers/status_action_provider.dart';
import '../providers/status_providers.dart';

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

class _StatusScreenState extends ConsumerState<StatusScreen> {
  /// `viewportFraction` is final on PageController and needs the reel's measured height, exactly
  /// as the feed's pager -> built lazily in [_pagerFor].
  PageController? _pager;
  double? _pagerFraction;

  /// Captured in initState -> `ref` is unusable from dispose(), where the pool is detached.
  late final VideoPreloadController<StatusVideo> _video;

  int _index = 0;
  List<StatusVideo>? _served;
  int? _pendingIndex;

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
    final target = ArulDeepLink.consumeStatus();
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

  Future<void> _doShare(StatusVideo status) async {
    final l10n = AppLocalizations.of(context);
    final outcome = await ref
        .read(statusActionProvider.notifier)
        .shareToWhatsApp(status, buildCaption: l10n.referShareMessage);
    if (!mounted || outcome == null) return;
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
    final outcome = await ref.read(statusActionProvider.notifier).save(status);
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

    // Flag off (or not known yet): nothing below may watch the catalog -> no status fetch at all.
    // The shell moves the user off this branch; this only covers the frame before it does.
    final enabled = ref.watch(statusTabFlagProvider) ?? false;
    if (!enabled) return Scaffold(backgroundColor: frameColor);

    if (ref.watch(statusCatalogProvider) case AsyncData(:final value)) {
      _maybeOpenDeepLink(value);
    }
    final feed = ref.watch(statusFeedProvider);
    // Kept warm so a gated tap reads a resolved value instead of a fresh /me round trip.
    ref.watch(entitlementProvider);

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
                actions: [
                  ArulIconTap.glyph(
                    glyph: ArulLineGlyph.settings,
                    label: l10n.settingsTitle,
                    identifier: 'arul_header_settings',
                    onTap: () => context.push('/settings'),
                  ),
                ],
                chips: feed is AsyncLoading
                    ? const FeedChipsSkeleton()
                    : const StatusChips(),
              ),
              Expanded(
                // One LayoutBuilder for loading AND reel -> the skeleton and the card share a rect.
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final geo = FeedCardGeometry.resolve(
                      context,
                      reelHeight: constraints.maxHeight,
                    );
                    return switch (feed) {
                      AsyncLoading() => FeedLoading(
                        margin: geo.margin,
                        radius: FeedCardGeometry.radius,
                      ),
                      AsyncData(:final value) when value.isEmpty =>
                        StateView.empty(title: l10n.statusEmpty),
                      AsyncData(:final value) => _buildReel(
                        value,
                        geo,
                        constraints.maxHeight,
                        l10n,
                      ),
                      AsyncError() => StateView.error(
                        title: l10n.statusError,
                        message: l10n.feedErrorBody,
                        actionLabel: l10n.retry,
                        actionIdentifier: 'arul_status_retry',
                        onAction: () => unawaited(
                          ref.read(statusCatalogProvider.notifier).refresh(),
                        ),
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
      statusActionProvider.select((s) => s is StatusActionBusy),
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
          child: PageView.builder(
            controller: _pagerFor(geo, geo.pagerHeight(h)),
            scrollDirection: Axis.vertical,
            padEnds: false,
            itemCount: items.length,
            onPageChanged: (i) {
              setState(() => _index = i);
              _video.onPageChanged(i);
              _onCardSettled(items[i]);
            },
            itemBuilder: (context, i) => Padding(
              padding: m.copyWith(bottom: FeedCardGeometry.gap),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(FeedCardGeometry.radius),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // Tap pauses and resumes; vertical drags still belong to the pager.
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _video.toggleHeldByUser,
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
                          image: const AssetImage('assets/images/whatsapp.webp'),
                          label: l10n.statusWhatsapp,
                          semanticsId: 'arul_status_whatsapp',
                          onTap: () => _onAction(StatusVerb.share, items[i]),
                        ),
                        secondary: ReelAction(
                          icon: Icons.file_download_outlined,
                          label: l10n.statusSave,
                          semanticsId: 'arul_status_save',
                          onTap: () => _onAction(StatusVerb.save, items[i]),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (busy)
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

  /// Centre, not the wallpapers' top-weighted crop: a status is composed around its middle line of
  /// text, and the top bias showed a fill band above the clip while cutting its lower words.
  static const _statusCrop = Alignment.center;

  @override
  Widget build(BuildContext context) {
    final slot = this.slot;
    final width =
        (MediaQuery.sizeOf(context).width *
                MediaQuery.devicePixelRatioOf(context))
            .round();
    return ColoredBox(
      color: ArulColors.ink,
      child: Stack(
        fit: StackFit.expand,
        children: [
          CachedNetworkImage(
            imageUrl: status.posterUrl(AppConfig.cdnBaseUrl),
            fit: BoxFit.cover,
            alignment: _statusCrop,
            memCacheWidth: width,
            fadeInDuration: Duration.zero,
            errorWidget: (_, _, _) => const SizedBox.shrink(),
          ),
          if (slot != null)
            ReelLiveTexture(slot: slot, alignment: _statusCrop),
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
