import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/l10n/app_localizations.dart';
import '../../../app/widgets/arul_chip.dart';
import '../../../app/widgets/arul_sheet.dart';
import '../../../app/widgets/arul_toast.dart';
import '../../../app/widgets/cta_button.dart';
import '../../../app/widgets/gopuram_mark.dart';
import '../../../core/config/app_config.dart';
import '../../../core/connectivity/connectivity_provider.dart';
import '../../../data/models/ringtone.dart';
import '../../../data/models/wallpaper.dart';
import '../../../theme/arul_tokens.dart';
import '../../premium/providers/entitlement_provider.dart';
import '../data/ringtone_set_service.dart';
import '../providers/ringtone_catalog_providers.dart';
import '../providers/ringtone_preview_provider.dart';
import '../providers/ringtone_set_provider.dart';
import 'ringtone_states.dart';

/// The Ringtones tab: category-chip browse over a scrollable list of ringtone
/// cards — preview free (streamed from the public CDN), "Set" premium-gated
/// via the Worker's signed-url check.
///
/// Same frame language as the wallpaper feed: brand header, category chips on
/// the themed surface, a full-width hairline floor, content below. Category is
/// THE browse axis (CLAUDE.md §5b) — the reference's All/New tabs are
/// deliberately not ported.
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
      // Ported from the reference: stop preview audio the moment the location
      // leaves /ringtones — this covers BOTH a pushed route (settings, premium
      // paywall) and a bottom-bar branch switch, where the IndexedStack keeps
      // this screen alive and no dispose/deactivate ever fires.
      _router = GoRouter.of(context);
      _routeListener = () {
        final loc = _router!.routeInformationProvider.value.uri.path;
        if (!loc.startsWith('/ringtones')) {
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
        case RingtoneSetError(:final isNetwork):
          ref.read(ringtoneSetProvider.notifier).reset();
          showArulToast(
            context,
            isNetwork ? l10n.offlineBody : l10n.ringtoneSetFailed,
            kind: ToastKind.error,
          );
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
          child: Column(
            children: [
              // Brand header — same composition as the feed's, so the two tabs
              // read as one app.
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
                    _SettingsButton(onTap: () => context.push('/settings')),
                  ],
                ),
              ),

              // Category chips — same chip visuals + fade as the feed's row.
              Stack(
                children: [
                  const _RingtoneChips(),
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

              // The header's floor — the same hairline the feed draws.
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Container(
                  height: 1,
                  color: isDark
                      ? ArulTokens.cardBorderDark14
                      : ArulTokens.cardBorderLight,
                ),
              ),

              // In-flight set pipeline: a gold hairline progress bar + stage
              // label directly under the header floor.
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
                          onRefresh: _refresh,
                          color: ArulTokens.gold,
                          backgroundColor: isDark
                              ? ArulTokens.darkSheetSurface
                              : ArulTokens.cardBgLight,
                          child: value.isEmpty
                              ? const RingtonesEmpty()
                              : _buildList(value),
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

  Widget _buildList(List<Ringtone> items) {
    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(
        ArulTokens.screenPadding,
        14,
        ArulTokens.screenPadding,
        14,
      ),
      itemCount: items.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, i) => _RingtoneCard(
        ringtone: items[i],
        onSet: () => _onSetTapped(items[i]),
      ),
    );
  }

  /// WRITE_SETTINGS explainer — the reference's permission sheet, restyled as
  /// an Arul sheet (dark #1A0B0F surface, gold hairline, grabber).
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

/// Ringtone-scoped clone of the feed's chip row: same [ArulChip] visuals, same
/// geometry, its OWN selected-category provider (tab filters never bleed
/// across). Skeleton pills render while categories are unknown.
class _RingtoneChips extends ConsumerWidget {
  const _RingtoneChips();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final categories = ref.watch(ringtoneCategoriesProvider);
    final selected = ref.watch(selectedRingtoneCategoryProvider);
    final loading = ref.watch(ringtoneCatalogProvider) is AsyncLoading;

    if (categories.isEmpty) {
      // Hold the row's height; sliding pills only while genuinely loading.
      if (!loading) return const SizedBox(height: 34);
      return const _ChipsSkeleton();
    }

    final items = <WallpaperCategory>[
      WallpaperCategory(WallpaperCategory.allSlug, l10n.categoryAll),
      ...categories,
    ];

    return SizedBox(
      height: 34,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.only(
          left: ArulTokens.screenPadding,
          right: 28,
        ),
        itemCount: items.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final c = items[i];
          return Center(
            child: ArulChip(
              label: c.label,
              selected: c.slug == selected,
              variant: ArulChipVariant.surface,
              onTap: () => ref
                  .read(selectedRingtoneCategoryProvider.notifier)
                  .select(c.slug),
            ),
          );
        },
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
        ? ArulTokens.ivory.withValues(alpha: 0.08)
        : ArulTokens.maroonTintFill08;
    return SizedBox(
      height: 34,
      child: Row(
        children: [
          const SizedBox(width: ArulTokens.screenPadding),
          for (final w in _widths) ...[
            Container(
              width: w,
              height: 32,
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
    return Column(
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
              color: isDark ? ArulTokens.darkMuted : ArulTokens.lightSecondary,
            ),
          ),
        ),
      ],
    );
  }
}

// ─── Ringtone card ────────────────────────────────────────────────────────────

/// One ringtone: rounded cover (or the decorated ♪ fallback) with a play/pause
/// preview overlay, title + category, and the "Set" pill.
class _RingtoneCard extends ConsumerWidget {
  const _RingtoneCard({required this.ringtone, required this.onSet});

  final Ringtone ringtone;
  final VoidCallback onSet;

  static const double _cover = 56;

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

    final isPlaying = preview.isPlayingId(ringtone.id);
    final isBuffering = preview.isLoadingId(ringtone.id);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark ? ArulTokens.cardBgDark05 : ArulTokens.cardBgLight,
        borderRadius: BorderRadius.circular(ArulTokens.cardRadius),
        border: Border.all(
          color: isDark
              ? (isPlaying
                    ? ArulTokens.goldBorder35
                    : ArulTokens.cardBorderDark09)
              : (isPlaying
                    ? ArulTokens.maroonBorder18
                    : ArulTokens.cardBorderLight),
        ),
      ),
      child: Row(
        children: [
          // ── Cover + preview toggle ─────────────────────────────────────
          Semantics(
            button: true,
            label: l10n.ringtonePreviewSemantic,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                HapticFeedback.lightImpact();
                ref.read(ringtonePreviewProvider.notifier).toggle(ringtone);
              },
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: SizedBox(
                  width: _cover,
                  height: _cover,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      _CoverArt(ringtone: ringtone),
                      // Scrim keeps the glyph legible over any cover art.
                      const DecoratedBox(
                        decoration: BoxDecoration(
                          color: Color.fromRGBO(20, 9, 12, 0.30),
                        ),
                      ),
                      Center(
                        child: isBuffering
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: ArulTokens.gold,
                                ),
                              )
                            : Icon(
                                isPlaying
                                    ? Icons.pause_rounded
                                    : Icons.play_arrow_rounded,
                                size: 26,
                                color: ArulTokens.ivory,
                                shadows: ArulTokens.railIconShadow,
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),

          // ── Title + category ──────────────────────────────────────────
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  ringtone.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ArulTokens.rowTitle.copyWith(
                    color: isDark ? ArulTokens.ivory : ArulTokens.lightText,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  ringtone.categoryLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ArulTokens.rowSub.copyWith(
                    color: isDark
                        ? ArulTokens.darkTextSecondary
                        : ArulTokens.lightSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),

          // ── Set pill — the feed Apply pill's language at card scale ───
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

/// Cover art, or the decorated fallback tile (gold ♪ on a maroon→darkSurface
/// silk gradient) when the catalog carries no cover — never a broken image.
class _CoverArt extends StatelessWidget {
  const _CoverArt({required this.ringtone});

  final Ringtone ringtone;

  @override
  Widget build(BuildContext context) {
    final url = ringtone.coverUrl(AppConfig.cdnBaseUrl);
    if (url == null) return const _FallbackTile();
    return CachedNetworkImage(
      imageUrl: url,
      fit: BoxFit.cover,
      memCacheWidth: (56 * MediaQuery.devicePixelRatioOf(context)).round(),
      placeholder: (_, _) => const _FallbackTile(),
      errorWidget: (_, _, _) => const _FallbackTile(),
    );
  }
}

class _FallbackTile extends StatelessWidget {
  const _FallbackTile();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [ArulTokens.maroon, ArulTokens.darkSurface],
        ),
      ),
      child: Center(
        child: Icon(
          Icons.music_note_rounded,
          size: 24,
          color: ArulTokens.gold.withValues(alpha: 0.9),
        ),
      ),
    );
  }
}

/// The card's primary verb, in the feed Apply pill's language scaled to a row:
/// solid ivory + maroon label on the dark frame, solid maroon + ivory label on
/// the light one.
class _SetPill extends StatelessWidget {
  const _SetPill({
    required this.label,
    required this.busy,
    required this.onTap,
  });

  final String label;
  final bool busy;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fill = isDark ? ArulTokens.ivory : ArulTokens.maroon;
    final fg = isDark ? ArulTokens.maroon : ArulTokens.ivory;
    final disabled = onTap == null;

    return Semantics(
      button: true,
      enabled: !disabled,
      label: label,
      child: Opacity(
        opacity: disabled && !busy ? 0.55 : 1,
        child: Material(
          color: fill,
          borderRadius: BorderRadius.circular(ArulTokens.pillRadius),
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
            child: Container(
              height: 36,
              constraints: const BoxConstraints(minWidth: 68),
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: Center(
                widthFactor: 1,
                child: busy
                    ? SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: fg,
                        ),
                      )
                    : Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ArulTokens.button.copyWith(
                          fontSize: 14,
                          color: fg,
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

// ─── Settings button (matches the feed header's) ─────────────────────────────

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
