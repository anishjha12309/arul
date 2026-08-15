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
import '../../../app/widgets/arul_sheet.dart';
import '../../../app/widgets/arul_toast.dart';
import '../../../app/widgets/cta_button.dart';
import '../../../core/analytics/analytics_provider.dart';
import '../../../core/connectivity/connectivity_provider.dart';
import '../../../core/haptics/arul_haptics.dart';
import '../../../data/models/ringtone.dart';
import '../../../data/models/wallpaper.dart';
import '../../../theme/arul_tokens.dart';
import '../../premium/providers/entitlement_provider.dart';
import '../data/ringtone_set_service.dart';
import '../providers/ringtone_catalog_providers.dart';
import '../providers/ringtone_preview_provider.dart';
import '../providers/ringtone_set_provider.dart';
import 'deity_art.dart';
import 'ringtone_states.dart';
import 'ringtone_tile.dart';

/// The Ringtones tab: a category-chip browse over a list of ringtone rows —
/// preview free (streamed from the public CDN), "Set" premium-gated via the
/// Worker's signed-url check.
///
/// Two things about it are load-bearing rather than decorative:
///
///   * **One value drives the whole now-playing look.** Row fill, border, title
///     colour, button fill/glyph and the cover-art diya all read the same
///     `currentId` from [ringtonePreviewProvider]. There is no per-row playing
///     flag to fall out of sync, and clearing it stops the audio.
///   * **The art is bundled, not fetched** ([RingtoneTile] over [deityAsset]) —
///     the catalog carries no cover images, only a `deity` slug the app maps to
///     one of 17 bundled PNGs. Nothing here can 404, so the list has no image
///     loading state at all, and its ground is still drawn per track so one
///     deity's 35 tracks are not 35 identical tiles.
///
/// Category is THE browse axis (CLAUDE.md §5b) — there are no All/New tabs.
class RingtonesScreen extends ConsumerStatefulWidget {
  const RingtonesScreen({super.key});

  @override
  ConsumerState<RingtonesScreen> createState() => _RingtonesScreenState();
}

class _RingtonesScreenState extends ConsumerState<RingtonesScreen> {
  GoRouter? _router;
  VoidCallback? _routeListener;

  // Cached so dispose() never touches ref (unusable there in Riverpod 3).
  RingtonePreviewNotifier? _previewNotifier;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _previewNotifier ??= ref.read(ringtonePreviewProvider.notifier);
    if (_router == null) {
      // Stop preview audio the moment the location leaves /ringtones — this
      // covers BOTH a pushed route (premium paywall, refer) and a dock branch
      // switch, where the IndexedStack keeps this screen alive and no
      // dispose/deactivate ever fires.
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
    _previewNotifier?.stop();
    super.dispose();
  }

  /// Premium gate for "Set as ringtone". Awaits the entitlement future
  /// (CLAUDE.md §5 — a loading snapshot must never bounce a premium user);
  /// on a free user, ensurePremium tracks `ringtone_set_blocked_premium` and
  /// routes `/premium?source=ringtone_set`.
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

    // Same rationale as the feed: keep the entitlement resolved while the tab
    // is up so the gate's await returns instantly on tap.
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

    // Set pipeline reactions: permission sheet / success toast / error toast.
    ref.listen(ringtoneSetProvider, (prev, next) {
      switch (next) {
        case RingtoneSetNeedsPermission():
          _showPermissionSheet(context);
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
            // The subscription lapsed mid-session and the server's live check
            // caught it. A toast is a dead end here — retrying fails
            // identically — so send them to the paywall.
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
          // The list runs full-bleed under the floating dock; its own bottom
          // inset (AppShell.dockClearance) covers the gesture bar, so a SafeArea
          // pad here would only double it up.
          bottom: false,
          child: Column(
            children: [
              // ── The browse frame ──────────────────────────────────────
              // Byte-for-byte the wallpaper feed's upper portion: same title
              // band, same chip row geometry, same gap, same hairline floor,
              // same drop to the content below it. The tabs cross-fade, so
              // anything that differed up here read as the screen jumping.
              ArulBrowseHeader(
                title: l10n.tabRingtones,
                // Literally the same control the wallpaper feed puts here, not
                // a matching one — same glyph, same word, same glint, same
                // destination. Two look-alike buttons is how they drifted
                // apart the first time.
                actions: [ArulEarnButton(onTap: () => context.push('/refer'))],
                chips: const _RingtoneChips(),
              ),

              // In-flight set pipeline: a gold hairline progress bar + stage
              // label, directly under the chips. Not in the handoff — the
              // handoff draws one resting moment, and this is the only place
              // that reports a multi-second download the user started.
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
    // The dev preview's sample tracks are injected at the CATALOG, not here, so
    // the chips and the category filter see them too — see
    // ringtone_catalog_providers.dart.
    if (items.isEmpty) return const RingtonesEmpty();
    return _buildList(items);
  }

  Widget _buildList(List<Ringtone> items) {
    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.fromLTRB(
        ArulTokens.screenPadding,
        0,
        ArulTokens.screenPadding,
        AppShell.dockClearance(context),
      ),
      itemCount: items.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, i) =>
          RingtoneRow(ringtone: items[i], onSet: () => _onSetTapped(items[i])),
    );
  }

  /// WRITE_SETTINGS explainer — restyled as an Arul sheet (dark #1A0B0F
  /// surface, gold hairline, grabber).
  void _showPermissionSheet(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    showArulSheet<void>(
      context,
      builder: (ctx) {
        final sheetDark = Theme.of(ctx).brightness == Brightness.dark;
        return Padding(
          padding: const EdgeInsets.fromLTRB(
            ArulTokens.cardPadding20,
            4,
            ArulTokens.cardPadding20,
            ArulTokens.cardPadding20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.ringtonePermissionTitle,
                style: ArulTokens.sheetTitle.copyWith(
                  color: sheetDark ? ArulTokens.ivory : ArulTokens.lightText,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                l10n.ringtonePermissionBody,
                style: ArulTokens.body.copyWith(
                  color: sheetDark
                      ? ArulTokens.darkBodyWarm
                      : ArulTokens.lightBody,
                ),
              ),
              const SizedBox(height: 20),
              CtaButton(
                label: l10n.ringtonePermissionCta,
                onPressed: () {
                  Navigator.of(ctx).pop();
                  ref.read(ringtoneSetProvider.notifier).openWriteSettings();
                },
              ),
              const SizedBox(height: 4),
              Center(
                child: TextButton(
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    ref.read(ringtoneSetProvider.notifier).reset();
                  },
                  child: Text(
                    l10n.ringtonePermissionCancel,
                    style: ArulTokens.button.copyWith(
                      color: sheetDark
                          ? ArulTokens.darkTextSecondary
                          : ArulTokens.lightSecondary,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ─── Chips row ────────────────────────────────────────────────────────────────

/// Ringtone-scoped chip row: the handoff's browse pills, its OWN selected-
/// category provider (tab filters never bleed across). Skeleton pills render
/// while categories are unknown. Scrolls horizontally with no scrollbar.
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
      // Nothing to browse by: take up NO height at all rather than holding an
      // empty 34px band, which reads as a gap the designer forgot. Sliding
      // pills only while a catalog is genuinely on its way.
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
        // The handoff's chip rail shows no scrollbar in either theme. copyWith
        // rather than a fresh ScrollBehavior, so the platform's physics and
        // overscroll treatment are untouched — only the bar goes.
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

// ─── Set progress ─────────────────────────────────────────────────────────────

/// Hairline gold progress + stage caption while the set pipeline runs.
/// Indeterminate outside the download stage (a bar parked at 0% reads stuck).
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

// ─── Ringtone row ─────────────────────────────────────────────────────────────

/// One ringtone: deity art, title over deity name, a circular play/pause, and
/// the outlined "Set" pill.
///
/// Public so the widget tests can find rows by type rather than by string.
class RingtoneRow extends ConsumerWidget {
  const RingtoneRow({super.key, required this.ringtone, required this.onSet});

  final Ringtone ringtone;
  final VoidCallback onSet;

  /// Handoff geometry, restated for the two-line row: `52 + 2×9 = 70` tall.
  /// The art drives the height — title + subtitle stack to ~38 — so a track
  /// with no deity makes a shorter text column, never a shorter row.
  static const double coverSize = RingtoneTile.defaultSize;
  static const double _padH = 12;
  static const double _padV = 9;

  /// The gap the handoff draws between the row's children. Both trailing
  /// controls lay out in a [ArulTokens.minHitTarget]-wide/tall box with the
  /// visual centred inside it, so the drawn gap is this plus that box's own
  /// slack — see [_PlayButton].
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

    // The medallion keeps its lit overlay through the buffering beat, so the
    // tile does not flash dark → lit when the stream finally opens.
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
                // The deity name, and the only place in the app that names the
                // god a track is to. Absent rather than blank when the catalog
                // carries no deity, so the title simply centres itself.
                //
                // Deliberately NOT tinted with the now-playing state: the title
                // going gold is the signal, and a second gold line under it
                // made the playing row read as selected-and-disabled.
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

/// The row's preview toggle: a 34px circle whose touch target is grown to the
/// 44px minimum by laying out in a 44px box with the circle centred — the
/// handoff is explicit that the visual stays 34 and only the hit area grows.
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
                    // Not in the handoff, which draws a settled state: a
                    // CDN stream can take a beat to open and a dead pause
                    // glyph would read as a failed tap.
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

/// The play triangle / pause bars, in the handoff's 24-unit viewBox. Filled
/// shapes, so they are not part of the stroke-only `ArulLineIcon` set.
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

/// The row's commit verb — outlined in both themes and identical whether or not
/// the row is playing, so the eye never mistakes it for the transport control.
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

  /// The widest the pill may grow. English "Set" is ~56 here, but the same
  /// string is "സെറ്റ് ചെയ്യുക" in Malayalam and the OS font-size setting can
  /// double it; unbounded, the pill would push the whole row off a 320dp
  /// screen, because a Row lays its inflexible children out first and only then
  /// hands the remainder to the title. Past this width the label ellipsises
  /// instead — a clipped verb beats a broken row.
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
          // Setting a ringtone is a commit verb — same weight as Apply on the
          // wallpaper feed. The outcome beat comes from the toast.
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
