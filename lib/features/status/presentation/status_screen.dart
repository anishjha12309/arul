import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/l10n/app_localizations.dart';
import '../../../app/widgets/arul_chip.dart';
import '../../../app/widgets/arul_icon_tap.dart';
import '../../../app/widgets/arul_line_icons.dart';
import '../../../app/widgets/arul_pressable.dart';
import '../../../app/widgets/arul_screen_header.dart';
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
import '../../../core/providers/locale_provider.dart';
import '../../../core/providers/shared_preferences_provider.dart';
import '../../../data/models/wallpaper.dart';
import '../../../theme/arul_palette.dart';
import '../../../theme/arul_tokens.dart';
import '../../premium/providers/entitlement_provider.dart';
import '../../settings/presentation/language_sheet.dart';
import '../../wallpapers/presentation/feed_states.dart';
import '../data/status_overlay.dart';
import '../domain/status_video.dart';
import '../providers/status_action_provider.dart';
import '../providers/status_persona_provider.dart';
import '../providers/status_providers.dart';
import 'status_persona_sheet.dart';
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

  /// Set once the first visit has asked the language (owner: never twice).
  static const languageAskedKey = 'arul_status_lang_asked';

  @override
  ConsumerState<StatusScreen> createState() => _StatusScreenState();
}

class _StatusScreenState extends ConsumerState<StatusScreen> {
  /// `viewportFraction` is final on PageController and needs the reel's measured height, exactly
  /// as the feed's pager -> built lazily in [_pagerFor].
  PageController? _pager;

  /// Captured in initState -> `ref` is unusable from dispose(), where the pool is detached.
  late final VideoPreloadController<StatusVideo> _video;

  int _index = 0;

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
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeAskLanguage());
  }

  /// Owner: the first Status visit asks the language ONCE and makes it the app language, so
  /// that language's statuses lead. A visit that arrives on a status link answers first.
  Future<void> _maybeAskLanguage() async {
    final prefs = ref.read(sharedPreferencesProvider);
    if (prefs.getBool(StatusScreen.languageAskedKey) ?? false) return;
    if (ArulDeepLink.pendingTarget is StatusLinkTarget) return;
    await prefs.setBool(StatusScreen.languageAskedKey, true);
    if (!mounted) return;
    final current = appLanguageName(ref.read(localeProvider).languageCode);
    final next = await showLanguageSheet(context, current);
    final code = next == null ? null : appLanguageCodeFor(next);
    if (code == null || !mounted) return;
    await ref
        .read(localeProvider.notifier)
        .setLocale(Locale(code), source: LanguageSource.pick);
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

  PageController _pagerFor() => _pager ??= PageController(initialPage: _index);

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
    if (_served == null && ref.read(activeStatusCategoryProvider) == allSlug) {
      _pendingIndex = index;
      // Pin All -> the app language's category must not take the reel once the link is spent.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ref.read(selectedStatusCategoryProvider.notifier).select(allSlug);
        }
      });
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
    unawaited(context.push(premiumGateRoute(ref, verb.source)));
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
    final p = ArulPalette.of(context);

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
        backgroundColor: p.surface,
        body: SafeArea(
          child: Column(
            children: [
              // Shubh's status header: the title band, then a 36 dp chip row and 12 dp of air -> every dp
              // the browse tabs spend above their reels here goes to the clip's width instead.
              ArulScreenHeader(
                title: l10n.statusTitle,
                actions: [
                  ArulIconTap.glyph(
                    glyph: ArulLineGlyph.settings,
                    label: l10n.settingsTitle,
                    identifier: 'arul_header_settings',
                    onTap: () => context.push('/settings'),
                  ),
                ],
              ),
              SizedBox(
                height: ArulChip.denseStripHeight,
                child: feed.hasValue
                    ? const StatusChips()
                    : const FeedChipsSkeleton(),
              ),
              const SizedBox(height: 12),
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
                              constraints.biggest,
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
                              margin: _pageMargin,
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

  /// Shubh's page: 12 dp either side, 4 dp above and below the clip's box.
  static const _pageMargin = EdgeInsets.symmetric(horizontal: 12);
  static const _pageInset = EdgeInsets.symmetric(horizontal: 12, vertical: 4);

  /// Below API 31 the export would crash, so the sheet explains instead (owner).
  Future<void> _openPersona() async {
    // A double tap would stack two sheets.
    if (_personaOpen) return;
    _personaOpen = true;
    try {
      final supported = await ref.read(statusPersonaSupportedProvider.future);
      if (!mounted) return;
      if (!supported) {
        await StatusPersonaSheet.showUnsupported(context);
        return;
      }
      await StatusPersonaSheet.show(context);
    } finally {
      _personaOpen = false;
    }
  }

  bool _personaOpen = false;

  Widget _buildReel(List<StatusVideo> items, Size reel, AppLocalizations l10n) {
    _sync(items);
    final busy = ref.watch(
      statusActionProvider.select((s) => s is! StatusActionIdle),
    );
    final p = ArulPalette.of(context);
    // One status per page, the whole reel (Shubh's status view): the clip's box is the largest of
    // its own shape inside the page, centred — no peek of the next clip, nothing beside the picture.
    // The page is the reel minus the bar under it; the clip's box is the largest of its shape inside.
    final box = _pageInset.deflateSize(
      Size(reel.width, reel.height - StatusActionBar.height),
    );

    final current = items[_index.clamp(0, items.length - 1)];
    final nameBand = ref.watch(statusNameBandProvider);
    // Shubh's status view: the clip alone on the page, the verbs in ONE fixed bar under the reel that
    // acts on the clip in view -> nothing of ours over the name strip or the photo slots.
    return Column(
      children: [
        Expanded(
          child: Stack(
      fit: StackFit.expand,
      children: [
        // A pull on the first card re-reads the catalog, exactly as the wallpaper reel's does;
        // on a later card the pull only pages back.
        RefreshIndicator(
          onRefresh: () {
            ArulHaptics.firm();
            return ref.read(statusCatalogProvider.notifier).refresh();
          },
          color: ArulTokens.gold,
          backgroundColor: p.surface,
          child: PageView.builder(
            controller: _pagerFor(),
            scrollDirection: Axis.vertical,
            physics: const AlwaysScrollableScrollPhysics(),
            itemCount: items.length,
            onPageChanged: (i) {
              setState(() => _index = i);
              _video.onPageChanged(i);
              _onCardSettled(items[i]);
            },
            itemBuilder: (context, i) {
              final status = items[i];
              // The name band sits under the clip, so the card is the clip plus the band, fitted as one.
              final height = status.height ?? 1824;
              final band = nameBand
                  ? StatusOverlaySpec.bandPxFor(height) / height
                  : 0.0;
              final card = FeedCardGeometry.contain(
                box,
                status.aspect * (1 + band),
              );
              return Center(
                child: SizedBox.fromSize(
                  size: card,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(
                      FeedCardGeometry.radius,
                    ),
                    child: ColoredBox(
                      color: ArulTokens.darkSurface,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          Positioned(
                            left: 0,
                            top: 0,
                            right: 0,
                            height: card.height / (1 + band),
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
                                        StatusMedia(status: status, slot: slot),
                                  ),
                                ),
                                IgnorePointer(
                                  child: _HeldMark(controller: _video, index: i),
                                ),
                              ],
                            ),
                          ),
                          Positioned.fill(
                            child: _PersonaLayer(
                              status: status,
                              onEdit: _openPersona,
                              onAddPhoto: _openPersona,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        if (_fetchingBehind)
          Positioned(
            top: 0,
            left: _pageMargin.left,
            right: _pageMargin.right,
            child: const _StatusTransferProgress(),
          ),
      ],
          ),
        ),
        StatusActionBar(
          busy: busy,
          onPhoto: _openPersona,
          onSave: () => _onAction(StatusVerb.save, current),
          onShare: () => _onAction(StatusVerb.share, current),
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
      color: ArulTokens.darkSurface,
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
    final selected = ref.watch(activeStatusCategoryProvider);
    if (categories.isEmpty) return const SizedBox.shrink();
    final all = WallpaperCategory(WallpaperCategory.allSlug, l10n.categoryAll);
    // The app language's category leads even All (owner); the provider already put it first.
    final lead = statusSlugForLanguage(ref.watch(localeProvider).languageCode);
    final items = categories.first.slug == lead
        ? <WallpaperCategory>[categories.first, all, ...categories.skip(1)]
        : <WallpaperCategory>[all, ...categories];
    return SizedBox(
      height: ArulChip.denseStripHeight,
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
            dense: true,
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

/// The user's photo and name painted over the clip exactly as the export burns them in, plus the
/// tap targets: the photo opens the sheet, an empty slot offers to add one.
class _PersonaLayer extends ConsumerWidget {
  const _PersonaLayer({
    required this.status,
    required this.onEdit,
    required this.onAddPhoto,
  });

  final StatusVideo status;
  final VoidCallback onEdit;
  final VoidCallback onAddPhoto;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(statusPersonaSupportedProvider).value != true) {
      return const SizedBox.shrink();
    }
    final persona = ref.watch(statusPersonaProvider).value;
    if (persona == null) return const SizedBox.shrink();
    final name = persona.showName ? ref.watch(statusPersonaNameProvider) : null;
    final spec = StatusOverlaySpec(
      photo: persona.shownPhoto,
      name: name,
      slot: status.photoSlot,
      clipHeightPx: status.height ?? 1824,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final layout = StatusOverlayLayout.of(constraints.biggest, spec);
        final spot =
            layout.photo ??
            StatusOverlayLayout.photoSpot(layout.clip.size, status.photoSlot);
        return Stack(
          fit: StackFit.expand,
          children: [
            IgnorePointer(
              child: CustomPaint(painter: StatusOverlayPainter(spec)),
            ),
            // Slots reach the clip's bottom edge; clipped like the painted photo, nothing spills on the band.
            Positioned.fromRect(
              rect: layout.clip,
              child: ClipRect(
                child: Stack(
                  children: [
                    if (persona.photo != null && persona.showPhoto)
                      Positioned.fromRect(
                        rect: spot,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: onEdit,
                        ),
                      )
                    else if (persona.showPhoto)
                      Positioned.fromRect(
                        rect: spot,
                        child: _AddPhotoMedallion(onTap: onAddPhoto),
                      ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Shubh's empty-profile placeholder in Arul's maroon and gold: it covers the clip's own slot art
/// until a photo is picked, and is never burnt into a shared or saved clip.
class _AddPhotoMedallion extends StatelessWidget {
  const _AddPhotoMedallion({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: AppLocalizations.of(context).statusAddPhoto,
      identifier: 'arul_status_add_photo',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          ArulHaptics.tap();
          onTap();
        },
        child: const Image(
          image: AssetImage('assets/images/status_add_photo.webp'),
          fit: BoxFit.contain,
          filterQuality: FilterQuality.medium,
        ),
      ),
    );
  }
}

/// Shubh's bottom bar: Photo and Save as quiet pills, the WhatsApp share filling the rest.
@visibleForTesting
class StatusActionBar extends StatelessWidget {
  const StatusActionBar({super.key, 
    required this.busy,
    required this.onPhoto,
    required this.onSave,
    required this.onShare,
  });

  /// What Shubh's reel gives its bar (its PageView keeps 56 clear under the template).
  static const height = 56.0;

  static const _gap = 8.0;

  final bool busy;
  final VoidCallback onPhoto;
  final VoidCallback onSave;
  final VoidCallback onShare;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final en = lookupAppLocalizations(const Locale('en'));
    final p = ArulPalette.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: p.surface,
        border: Border(top: BorderSide(color: p.divider)),
      ),
      child: SizedBox(
        height: height,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final fit = _BarFit.of(
                context,
                room: constraints.maxWidth - 2 * _gap,
                labels: [l10n.statusPhoto, l10n.statusSave, l10n.statusWhatsapp],
                english: [en.statusPhoto, en.statusSave, en.statusWhatsapp],
              );
              return Row(
                children: [
                  SizedBox(
                    width: fit.widths[0],
                    child: _BarPill(
                      icon: Icons.add_a_photo_outlined,
                      label: fit.labels[0],
                      showGlyph: fit.quietGlyphs,
                      padH: fit.padH,
                      identifier: 'arul_status_photo',
                      onTap: onPhoto,
                    ),
                  ),
                  const SizedBox(width: _gap),
                  SizedBox(
                    width: fit.widths[1],
                    child: _BarPill(
                      icon: Icons.file_download_outlined,
                      label: fit.labels[1],
                      showGlyph: fit.quietGlyphs,
                      padH: fit.padH,
                      identifier: 'arul_status_save',
                      onTap: busy ? null : onSave,
                    ),
                  ),
                  const SizedBox(width: _gap),
                  Expanded(
                    child: _BarPill(
                      image: const AssetImage('assets/images/whatsapp.webp'),
                      label: fit.labels[2],
                      showGlyph: true,
                      padH: fit.padH,
                      identifier: 'arul_status_whatsapp',
                      primary: true,
                      onTap: busy ? null : onShare,
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// How the three pills share the row, decided once for the whole bar: the translations with their
/// glyphs, else any label that does not fit in plain English (owner: an overflowing label reads in
/// English, never shrunk or cut), else the quiet pills without glyphs, else tighter padding.
class _BarFit {
  const _BarFit(this.labels, this.widths, this.quietGlyphs, this.padH);

  factory _BarFit.of(
    BuildContext context, {
    required double room,
    required List<String> labels,
    required List<String> english,
  }) {
    // Up to a dozen attempts re-measure the same six labels on every layout -> one TextPainter each.
    final measured = <String, double>{};
    double text(String s) => measured[s] ??= _BarPill.textWidth(context, s);
    _BarFit? attempt(List<String> chosen, {required bool glyphs, required double pad}) {
      // The quiet pills' 0.5 rim is padding too: a Container adds its border's width inside.
      double pill(int i, {required bool glyph}) =>
          2 * pad +
          (i < 2 ? 1 : 0) +
          (glyph ? _BarPill.glyphSize + _BarPill.glyphGap : 0) +
          text(chosen[i]);
      final widths = [pill(0, glyph: glyphs), pill(1, glyph: glyphs), pill(2, glyph: true)];
      final need = widths.reduce((a, b) => a + b);
      return need <= room ? _BarFit(chosen, widths, glyphs, pad) : null;
    }

    // A label only switches language when IT is the one that cannot fit: the widest English
    // fallback first, so a bar that overflows by one word changes one word.
    final mixed = [...labels];
    final order = [0, 1, 2]..sort((a, b) => text(labels[b]).compareTo(text(labels[a])));
    final steps = <List<String>>[
      [...labels],
      for (final i in order) [...(mixed..[i] = english[i])],
    ];
    for (final pad in [12.0, 8.0]) {
      for (final glyphs in [true, false]) {
        for (final chosen in steps) {
          final fit = attempt(chosen, glyphs: glyphs, pad: pad);
          if (fit != null) return fit;
        }
      }
    }
    // Nothing fits even in English, glyph-less and tight: English, and the share keeps the rest.
    final last = attempt(english, glyphs: false, pad: 8);
    return last ?? _BarFit(english, [room * 0.3, room * 0.3, room * 0.4], false, 8);
  }

  final List<String> labels;

  /// Natural widths; the share's is only a floor, it fills the rest of the row.
  final List<double> widths;
  final bool quietGlyphs;
  final double padH;
}

class _BarPill extends StatelessWidget {
  const _BarPill({
    required this.label,
    required this.identifier,
    required this.onTap,
    required this.showGlyph,
    required this.padH,
    this.icon,
    this.image,
    this.primary = false,
  });

  final IconData? icon;
  final ImageProvider? image;
  final String label;
  final String identifier;
  final VoidCallback? onTap;
  final bool showGlyph;
  final double padH;

  /// The share: the green CTA fill, white glyph and label, widened to the rest of the row.
  final bool primary;

  static const glyphSize = 18.0;
  static const glyphGap = 5.0;

  static TextStyle style(Color ink) => ArulTokens.button.copyWith(
    fontSize: 13.5,
    fontWeight: FontWeight.w600,
    color: ink,
  );

  /// The label's laid-out width at the phone's own text scale, plus rounding slack.
  static double textWidth(BuildContext context, String text) {
    // Merged over the inherited style, exactly as the Text will be, or the two disagree on the font.
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        // Only the width matters here -> any ink will do.
        style: DefaultTextStyle.of(context).style.merge(style(ArulTokens.ivory)),
      ),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = painter.width.ceilToDouble() + 2;
    painter.dispose();
    return width;
  }

  @override
  Widget build(BuildContext context) {
    final p = ArulPalette.of(context);
    final ink = primary ? ArulTokens.onCta : p.text;
    final image = this.image;
    return ArulPressable(
      identifier: identifier,
      semanticLabel: label,
      haptic: ArulHapticStyle.firm,
      onTap: onTap,
      builder: (context, _) => Opacity(
        opacity: onTap == null ? 0.55 : 1,
        child: Container(
          height: double.infinity,
          padding: EdgeInsets.symmetric(horizontal: padH),
          decoration: BoxDecoration(
            color: primary ? ArulTokens.ctaGreen : p.controlFill,
            borderRadius: BorderRadius.circular(22),
            border: primary ? null : Border.all(color: p.border, width: 0.5),
          ),
          alignment: Alignment.center,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (showGlyph) ...[
                if (image != null)
                  Image(image: image, width: glyphSize, height: glyphSize)
                else if (icon != null)
                  Icon(icon, size: 17, color: p.controlInk),
                const SizedBox(width: glyphGap),
              ],
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: style(ink),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
