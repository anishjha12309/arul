import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/l10n/app_localizations.dart';
import '../../../app/shell/app_shell.dart';
import '../../../app/widgets/arul_chip.dart';
import '../../../app/widgets/arul_browse_header.dart';
import '../../../app/widgets/arul_earn_button.dart';
import '../../../app/widgets/arul_toast.dart';
import '../../../core/analytics/analytics_provider.dart';
import '../../../core/connectivity/connectivity_provider.dart';
import '../../../core/deeplink/deep_link_target.dart';
import '../../../core/haptics/arul_haptics.dart';
import '../../../data/models/ringtone.dart';
import '../../../data/models/wallpaper.dart';
import '../../../theme/arul_tokens.dart';
import '../../premium/providers/entitlement_provider.dart';
import '../../referral/providers/referral_providers.dart';
import '../data/ringtone_set_service.dart';
import '../providers/ringtone_catalog_providers.dart';
import '../providers/ringtone_preview_provider.dart';
import '../providers/ringtone_set_provider.dart';
import 'deity_art.dart';
import 'ringtone_states.dart';
import 'ringtone_tile.dart';

/// The Ringtones tab — a category-chip browse over rows; preview free, "Set" premium-gated.
///
///   * **One value drives the whole now-playing look** — fill, border, title, button and diya all
///     read the same `currentId`. No per-row flag can fall out of sync, and clearing it stops audio;
///   * **The art is BUNDLED, not fetched** — the catalog carries only a `deity` slug the app maps
///     to one of 17 PNGs. Nothing here can 404, so the list has no image loading state at all.
///
/// The ground is still drawn per track, so one deity's 35 tracks are not 35 identical tiles.
/// Category is THE browse axis (CLAUDE.md §5b) — there are no All/New tabs.
class RingtonesScreen extends ConsumerStatefulWidget {
  const RingtonesScreen({super.key});

  @override
  ConsumerState<RingtonesScreen> createState() => _RingtonesScreenState();
}

class _RingtonesScreenState extends ConsumerState<RingtonesScreen> {
  GoRouter? _router;
  VoidCallback? _routeListener;

  // Cached so dispose() never touches ref — unusable there in Riverpod 3.
  RingtonePreviewNotifier? _previewNotifier;

  /// The list's own controller, so a deep link can put its row at the top.
  final ScrollController _scroll = ScrollController();

  /// The gap [_buildList] draws between rows — part of the deep-link scroll arithmetic.
  static const double _rowGap = 10;

  /// Row a link asked for, as an index into the All list, waiting for layout.
  /// Consumed by [_scheduleDeepLinkScroll].
  int? _pendingScrollIndex;

  @override
  void initState() {
    super.initState();
    // _maybeOpenDeepLink runs from build() -> a target landing on an already-built screen must
    // trigger one, or nothing re-runs it.
    ArulDeepLink.changes.addListener(_onDeepLinkChanged);
  }

  void _onDeepLinkChanged() {
    scheduleMicrotask(() {
      if (mounted) setState(() {});
    });
  }

  /// Open the ringtone a link asked for — the ringtone twin of the feed's `maybeOpenDeepLink`.
  ///
  /// Always lands on **All**, never the ringtone's own category — All is the only chip with every row.
  /// The index resolves through [ringtoneFeedOrder]: a position in the list the tab SERVES.
  /// The row scrolls to the TOP and nothing auto-plays — preview is a tap the user makes.
  /// A miss is silent and normal: the ringtone may have been unpublished since the ad was built.
  /// Takes ONLY a ringtone target; a pending wallpaper passes through untouched for the feed.
  void _maybeOpenDeepLink(List<Ringtone> all) {
    if (all.isEmpty) return;
    final target = ArulDeepLink.consumeRingtone();
    if (target == null) return;

    // Clear the deferred copy too — it and ArulDeepLink are seeded together, either can win the race.
    unawaited(ref.read(installReferrerServiceProvider).clearPendingTarget());

    const allSlug = WallpaperCategory.allSlug;
    final index = ringtoneFeedOrder(
      allSlug,
      all,
    ).indexWhere((r) => r.id == target.id);
    if (index < 0) return;

    // GA4-only (not on the PostHog allow-list, not a Meta ★ event).
    ref
        .read(analyticsServiceProvider)
        .track('deep_link_opened', properties: target.analyticsProperties);

    _pendingScrollIndex = index;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // No-op when All is already selected; otherwise the chip change rebuilds and schedules it.
      ref.read(selectedRingtoneCategoryProvider.notifier).select(allSlug);
    });
  }

  /// Once the All list is built, jump the pending row to the top.
  /// Every row is [RingtoneRow.extent] tall with no top padding -> the offset is pure arithmetic.
  void _scheduleDeepLinkScroll() {
    final index = _pendingScrollIndex;
    if (index == null) return;
    if (ref.read(selectedRingtoneCategoryProvider) !=
        WallpaperCategory.allSlug) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _pendingScrollIndex = null;
      final offset = index * (RingtoneRow.extent + _rowGap);
      _scroll.jumpTo(offset.clamp(0.0, _scroll.position.maxScrollExtent));
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _previewNotifier ??= ref.read(ringtonePreviewProvider.notifier);
    if (_router == null) {
      // Stop preview audio the moment the location leaves /ringtones.
      // Covers a pushed route AND a dock branch switch, where nothing is ever disposed.
      _router = GoRouter.of(context);
      _routeListener = () {
        final loc = _router!.routeInformationProvider.value.uri.path;
        if (!loc.contains('ringtones')) {
          _previewNotifier?.stop();
        }
      };
      _router!.routeInformationProvider.addListener(_routeListener!);
    }
  }

  @override
  void dispose() {
    if (_routeListener != null) {
      _router?.routeInformationProvider.removeListener(_routeListener!);
    }
    ArulDeepLink.changes.removeListener(_onDeepLinkChanged);
    _scroll.dispose();
    _previewNotifier?.stop();
    super.dispose();
  }

  /// Premium gate for "Set as ringtone" — AWAITS the entitlement future (CLAUDE.md §5).
  /// A loading snapshot must never bounce a premium user.
  /// On a free user ensurePremium tracks the block and routes `/premium?source=ringtone_set`.
  Future<void> _onSetTapped(Ringtone ringtone) async {
    if (!await ensurePremium(context, ref, source: 'ringtone_set')) return;
    // Phone ringtone only — no alarm/notification choice in Arul's UI.
    unawaited(
      ref
          .read(ringtoneSetProvider.notifier)
          .setRingtone(ringtone, RingtoneTarget.ringtone),
    );
  }

  Future<void> _refresh() =>
      ref.read(ringtoneCatalogProvider.notifier).refresh();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final feed = ref.watch(ringtoneFeedProvider);

    // Open any ringtone a link asked for, once the FULL catalog is in — an id needs a row index.
    // Re-checked on every build, because a target can land after the first catalog.
    if (ref.watch(ringtoneCatalogProvider) case AsyncData(:final value)) {
      _maybeOpenDeepLink(value);
    }

    // Keep the entitlement resolved while the tab is up -> the gate's await returns instantly.
    ref.watch(entitlementProvider);

    // Preview failure → localized toast, once per error tick.
    ref.listen(ringtonePreviewProvider, (prev, next) {
      if (next.hasError && !(prev?.hasError ?? false)) {
        showArulToast(
          context,
          l10n.ringtonePreviewUnavailable,
          kind: ToastKind.error,
        );
        ref.read(ringtonePreviewProvider.notifier).clearError();
      }
    });

    // Set-pipeline reactions: success toast, error toast.
    // A missing WRITE_SETTINGS opens the system grant screen and returns to idle — nothing to show.
    ref.listen(ringtoneSetProvider, (prev, next) {
      switch (next) {
        case RingtoneSetSuccess():
          ref.read(ringtoneSetProvider.notifier).reset();
          showArulToast(
            context,
            l10n.ringtoneSetSuccess,
            kind: ToastKind.success,
          );
        case RingtoneSetError(:final isNetwork, :final premiumRequired):
          ref.read(ringtoneSetProvider.notifier).reset();
          if (premiumRequired && !isNetwork) {
            // The subscription lapsed mid-session and the server's live check caught it.
            // A toast is a dead end — retrying fails identically -> send them to the paywall.
            ref
                .read(analyticsServiceProvider)
                .track('ringtone_set_blocked_premium');
            context.push('/premium?source=ringtone_set');
          } else {
            showArulToast(
              context,
              isNetwork ? l10n.offlineBody : l10n.ringtoneSetFailed,
              kind: ToastKind.error,
            );
          }
        default:
          break;
      }
    });

    final offline = ref.watch(isOnlineProvider).value == false;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final frameColor = isDark ? ArulTokens.darkSurface : ArulTokens.ivory;
    final setState_ = ref.watch(ringtoneSetProvider);

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
          // The list runs full-bleed under the dock, and its own inset covers the gesture bar.
          // A SafeArea pad here would only double that up.
          bottom: false,
          child: Column(
            children: [
              // The browse frame is byte-for-byte the wallpaper feed's upper portion.
              // The tabs cross-fade -> anything that differed up here read as the screen jumping.
              ArulBrowseHeader(
                title: l10n.tabRingtones,
                // Literally the SAME control the feed puts here, not a matching one.
                // Two look-alike buttons is how they drifted apart the first time.
                actions: [ArulEarnButton(onTap: () => context.push('/refer'))],
                chips: const _RingtoneChips(),
              ),

              // In-flight set pipeline — a gold hairline bar and stage label, under the chips.
              // Not in the handoff, which draws one resting moment.
              // This is the only place that reports a multi-second download the user started.
              if (setState_ is RingtoneSetLoading)
                _SetProgress(state: setState_, l10n: l10n),

              Expanded(
                child: offline
                    ? RingtonesError(
                        offline: true,
                        onRetry: () {
                          ref.invalidate(isOnlineProvider);
                          ref.invalidate(ringtoneCatalogProvider);
                        },
                      )
                    : switch (feed) {
                        AsyncLoading() => const RingtonesLoading(),
                        AsyncData(:final value) => RefreshIndicator(
                          // Fires when the pull commits, not per drag pixel.
                          onRefresh: () {
                            ArulHaptics.firm();
                            return _refresh();
                          },
                          color: ArulTokens.gold,
                          backgroundColor: isDark
                              ? ArulTokens.darkSheetSurface
                              : ArulTokens.cardBgLight,
                          child: _buildBody(value),
                        ),
                        AsyncError() => RingtonesError(
                          onRetry: () =>
                              ref.invalidate(ringtoneCatalogProvider),
                        ),
                      },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody(List<Ringtone> items) {
    // Sample tracks are injected at the CATALOG, not here -> the chips and the filter see them too.
    if (items.isEmpty) return const RingtonesEmpty();
    return _buildList(items);
  }

  Widget _buildList(List<Ringtone> items) {
    _scheduleDeepLinkScroll();
    return ListView.separated(
      controller: _scroll,
      physics: const AlwaysScrollableScrollPhysics(),
      // Top padding stays ZERO — the deep-link scroll computes its offset from the row extent alone.
      padding: EdgeInsets.fromLTRB(
        ArulTokens.screenPadding,
        0,
        ArulTokens.screenPadding,
        AppShell.dockClearance(context),
      ),
      itemCount: items.length,
      separatorBuilder: (_, _) => const SizedBox(height: _rowGap),
      itemBuilder: (context, i) =>
          RingtoneRow(ringtone: items[i], onSet: () => _onSetTapped(items[i])),
    );
  }
}

/// Ringtone-scoped chip row — the handoff's browse pills, with its OWN selected-category provider.
/// Tab filters never bleed across.
/// Skeleton pills render while categories are unknown; scrolls horizontally with no scrollbar.
class _RingtoneChips extends ConsumerWidget {
  const _RingtoneChips();

  static const double _height = 34;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final categories = ref.watch(ringtoneCategoriesProvider);
    final selected = ref.watch(selectedRingtoneCategoryProvider);
    final loading = ref.watch(ringtoneCatalogProvider) is AsyncLoading;

    if (categories.isEmpty) {
      // Nothing to browse by -> take up NO height; an empty 34px band reads as a forgotten gap.
      // Sliding pills only while a catalog is genuinely on its way.
      if (!loading) return const SizedBox.shrink();
      return const _ChipsSkeleton();
    }

    final items = <WallpaperCategory>[
      WallpaperCategory(WallpaperCategory.allSlug, l10n.categoryAll),
      ...categories,
    ];

    return SizedBox(
      height: _height,
      child: ScrollConfiguration(
        // The handoff's chip rail shows no scrollbar in either theme.
        // copyWith, not a fresh ScrollBehavior -> physics and overscroll are untouched, only the bar.
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
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
              onTap: () => ref
                  .read(selectedRingtoneCategoryProvider.notifier)
                  .select(c.slug),
            );
          },
        ),
      ),
    );
  }
}

class _ChipsSkeleton extends StatelessWidget {
  const _ChipsSkeleton();

  static const _widths = [64.0, 84.0, 92.0];

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fill = isDark
        ? ArulTokens.cardBgDark045
        : ArulTokens.maroonTintFill08;
    return SizedBox(
      height: _RingtoneChips._height,
      child: Row(
        children: [
          const SizedBox(width: ArulTokens.screenPadding),
          for (final w in _widths) ...[
            Container(
              width: w,
              height: _RingtoneChips._height,
              decoration: BoxDecoration(
                color: fill,
                borderRadius: BorderRadius.circular(ArulTokens.pillRadius),
              ),
            ),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }
}

/// Hairline gold progress and a stage caption while the set pipeline runs.
/// Indeterminate outside the download stage — a bar parked at 0% reads stuck.
class _SetProgress extends StatelessWidget {
  const _SetProgress({required this.state, required this.l10n});

  final RingtoneSetLoading state;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final label = switch (state.stage) {
      RingtoneSetStage.checkingPermission ||
      RingtoneSetStage.fetchingUrl => l10n.ringtoneSetPreparing,
      RingtoneSetStage.downloading => l10n.ringtoneSetDownloading,
      RingtoneSetStage.setting => l10n.ringtoneSetApplying,
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        children: [
          LinearProgressIndicator(
            value: state.stage == RingtoneSetStage.downloading
                ? state.progress
                : null,
            minHeight: 3,
            backgroundColor: const Color(0x00000000),
            color: ArulTokens.gold,
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              label,
              style: ArulTokens.caption.copyWith(
                color: isDark
                    ? ArulTokens.darkMuted
                    : ArulTokens.lightSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One ringtone — deity art, title over deity name, a circular play/pause, the outlined "Set" pill.
///
/// Public so the widget tests can find rows by type rather than by string.
class RingtoneRow extends ConsumerWidget {
  const RingtoneRow({super.key, required this.ringtone, required this.onSet});

  final Ringtone ringtone;
  final VoidCallback onSet;

  /// Handoff geometry for the two-line row: `52 + 2×9 = 70` tall.
  /// The ART drives the height -> a track with no deity makes a shorter text column, not a shorter row.
  static const double coverSize = RingtoneTile.defaultSize;
  static const double _padH = 12;
  static const double _padV = 9;
  static const double _borderWidth = 1;

  /// The row's laid-out height — art, vertical padding, and the hairline border on both edges.
  /// NOTHING else may grow it; the text column and both controls fit inside the art's height.
  /// The deep-link scroll multiplies this out -> a taller row puts the WRONG ringtone at the top.
  static const double extent = coverSize + 2 * _padV + 2 * _borderWidth;

  /// The gap the handoff draws between the row's children.
  /// Both trailing controls centre their visual in a [ArulTokens.minHitTarget] box.
  /// So the DRAWN gap is this plus that box's own slack — see [_PlayButton].
  static const double _gap = 12;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final preview = ref.watch(ringtonePreviewProvider);
    final setStateValue = ref.watch(ringtoneSetProvider);
    final setBusy = setStateValue is RingtoneSetLoading;
    final setLoadingThis =
        setStateValue is RingtoneSetLoading &&
        setStateValue.ringtoneId == ringtone.id;

    // ONE value drives every now-playing affordance in this row.
    final isPlaying = preview.isPlayingId(ringtone.id);
    final isBuffering = preview.isLoadingId(ringtone.id);

    // The medallion keeps its lit overlay through buffering -> no dark → lit flash when it opens.
    final lit = isPlaying || isBuffering;

    final playSlack = (ArulTokens.minHitTarget - _PlayButton.visualSize) / 2;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: _padH, vertical: _padV),
      decoration: BoxDecoration(
        color: lit
            ? ArulTokens.goldTintFill10
            : (isDark ? ArulTokens.cardBgDark045 : ArulTokens.cardBgLight),
        borderRadius: BorderRadius.circular(ArulTokens.rowRadius),
        border: Border.all(
          // Explicit so [extent] and this can never disagree.
          width: _borderWidth,
          color: lit
              ? ArulTokens.goldBorder52
              : (isDark
                    ? ArulTokens.cardBorderDark09
                    : ArulTokens.cardBorderLight),
        ),
      ),
      child: Row(
        children: [
          RingtoneTile(
            spec: RingtoneTileSpec.forRingtone(id: ringtone.id),
            assetPath: deityAsset(
              deity: ringtone.deity,
              category: ringtone.category,
            ),
            playing: lit,
            size: coverSize,
          ),
          const SizedBox(width: _gap),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  ringtone.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ArulTokens.rowTitleTracked.copyWith(
                    color: lit
                        ? (isDark
                              ? ArulTokens.gold
                              : ArulTokens.nowPlayingTitleLight)
                        : (isDark ? ArulTokens.ivory : ArulTokens.lightText),
                  ),
                ),
                // The deity name — the only place in the app that names the god a track is to.
                // ABSENT rather than blank when there is no deity, so the title centres itself.
                // Deliberately NOT tinted by now-playing: a second gold line read as disabled.
                if (ringtone.deityLabel case final label?)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ArulTokens.caption.copyWith(
                        color: isDark
                            ? ArulTokens.darkMuted
                            : ArulTokens.lightSecondary,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          SizedBox(width: _gap - playSlack),
          _PlayButton(
            playing: isPlaying,
            buffering: isBuffering,
            semanticLabel: l10n.ringtonePreviewSemantic,
            onTap: () =>
                ref.read(ringtonePreviewProvider.notifier).toggle(ringtone),
          ),
          SizedBox(width: _gap - playSlack),
          _SetPill(
            label: l10n.ringtoneSet,
            busy: setLoadingThis,
            onTap: setBusy ? null : onSet,
          ),
        ],
      ),
    );
  }
}

/// The row's preview toggle — a 34px circle centred in a 44px box.
/// The handoff is explicit: the VISUAL stays 34 and only the hit area grows.
class _PlayButton extends StatelessWidget {
  const _PlayButton({
    required this.playing,
    required this.buffering,
    required this.semanticLabel,
    required this.onTap,
  });

  final bool playing;
  final bool buffering;
  final String semanticLabel;
  final VoidCallback onTap;

  static const double visualSize = 34;
  static const double _glyphSize = 15;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final lit = playing || buffering;

    final fill = lit
        ? ArulTokens.gold
        : (isDark ? const Color(0x00000000) : ArulTokens.cardBgLight);
    final border = lit
        ? ArulTokens.gold
        : (isDark ? ArulTokens.ivoryBorder22 : ArulTokens.maroonBorder18);
    final glyph = lit
        ? ArulTokens.darkSurface
        : (isDark ? ArulTokens.ivory : ArulTokens.lightText);

    return Semantics(
      button: true,
      toggled: playing,
      label: semanticLabel,
      child: GestureDetector(
        onTapDown: (_) => ArulHaptics.tap(),
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: SizedBox.square(
          dimension: ArulTokens.minHitTarget,
          child: Center(
            child: Container(
              width: visualSize,
              height: visualSize,
              decoration: BoxDecoration(
                color: fill,
                shape: BoxShape.circle,
                border: Border.all(color: border),
                boxShadow: lit ? ArulTokens.nowPlayingButtonGlow : null,
              ),
              child: Center(
                child: buffering
                    // Not in the handoff, which draws a settled state.
                    // A CDN stream takes a beat to open, and a dead pause glyph reads as a failed tap.
                    ? SizedBox.square(
                        dimension: _glyphSize,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: glyph,
                        ),
                      )
                    : _TransportIcon(
                        playing: playing,
                        size: _glyphSize,
                        color: glyph,
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The play triangle and pause bars, in the handoff's 24-unit viewBox.
/// FILLED shapes -> not part of the stroke-only `ArulLineIcon` set.
class _TransportIcon extends StatelessWidget {
  const _TransportIcon({
    required this.playing,
    required this.size,
    required this.color,
  });

  final bool playing;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: CustomPaint(
      painter: _TransportIconPainter(playing: playing, color: color),
    ),
  );
}

class _TransportIconPainter extends CustomPainter {
  const _TransportIconPainter({required this.playing, required this.color});

  final bool playing;
  final Color color;

  static const double _vb = 24;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / _vb);
    final paint = Paint()
      ..color = color
      ..isAntiAlias = true;

    if (playing) {
      // Two rounded bars: 8,6 and 13.2,6 — 3.2 × 12, r1.1.
      for (final x in const [8.0, 13.2]) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(x, 6, 3.2, 12),
            const Radius.circular(1.1),
          ),
          paint,
        );
      }
    } else {
      canvas.drawPath(
        Path()
          ..moveTo(8.6, 6.4)
          ..lineTo(17.6, 12)
          ..lineTo(8.6, 17.6)
          ..close(),
        paint,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_TransportIconPainter old) =>
      old.playing != playing || old.color != color;
}

/// The row's commit verb — outlined in both themes and identical whether or not the row is playing.
/// So the eye never mistakes it for the transport control.
/// Lays out at the 44px minimum height with the 32px pill centred inside.
class _SetPill extends StatelessWidget {
  const _SetPill({
    required this.label,
    required this.busy,
    required this.onTap,
  });

  final String label;
  final bool busy;
  final VoidCallback? onTap;

  static const double _visualHeight = 32;

  /// The widest the pill may grow.
  ///
  /// English "Set" is ~56, but Malayalam is far longer and the OS font size can double it.
  /// A Row lays its inflexible children out FIRST -> unbounded, the pill pushes the row off screen.
  /// Past this width the label ellipsises instead — a clipped verb beats a broken row.
  static const double _maxWidth = 120;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final border = isDark
        ? ArulTokens.ivoryBorder22
        : ArulTokens.maroonBorder18;
    final fg = isDark ? ArulTokens.ivoryText86 : ArulTokens.maroon;
    final disabled = onTap == null;

    return Semantics(
      button: true,
      enabled: !disabled,
      label: label,
      child: Opacity(
        opacity: disabled && !busy ? 0.55 : 1,
        child: GestureDetector(
          // Setting a ringtone is a commit verb — the same weight as Apply. The toast is the outcome.
          onTapDown: disabled ? null : (_) => ArulHaptics.firm(),
          onTap: disabled ? null : onTap,
          behavior: HitTestBehavior.opaque,
          child: SizedBox(
            height: ArulTokens.minHitTarget,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: _maxWidth),
                child: Container(
                  height: _visualHeight,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(ArulTokens.pillRadius),
                    border: Border.all(color: border),
                  ),
                  child: Center(
                    widthFactor: 1,
                    child: busy
                        ? SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: fg,
                            ),
                          )
                        : Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: ArulTokens.chipActive.copyWith(color: fg),
                          ),
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
