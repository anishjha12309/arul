import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/haptics/arul_haptics.dart';
import '../../features/ringtones/providers/ringtone_catalog_providers.dart';
import '../../features/ringtones/providers/ringtone_preview_provider.dart';
import '../../features/wallpapers/providers/video_preload_provider.dart';
import '../../theme/arul_tokens.dart';
import '../l10n/app_localizations.dart';
import '../widgets/arul_line_icons.dart';

/// The tabbed scaffold around the three top-level surfaces (Wallpapers /
/// Ringtones / Settings). Everything else — refer, upload, premium, the
/// settings sub-screens — pushes OVER this shell as a full-screen route.
///
/// The [StatefulShellRoute.indexedStack] keeps every branch alive, which is
/// what makes tab switches instant — but it also means neither media system
/// tears itself down when its tab hides. This widget is the referee:
///
///   * leaving Wallpapers → `releaseDecoders()` frees every hardware decoder
///     the feed's native pool holds (budget SoCs have only a handful, and the
///     hidden feed must never keep playing behind the ringtone list);
///   * returning → `reclaimDecoders()` reconciles the pool back onto the
///     feed's current page (its list/index survive in the app-scoped
///     controller);
///   * leaving Ringtones → preview audio stops (also covered by the screen's
///     own route listener; the double-stop is idempotent).
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  static const int wallpapersBranch = 0;
  static const int ringtonesBranch = 1;
  static const int settingsBranch = 2;

  /// How much bottom padding a scrollable owes the floating dock, which
  /// overlays it (`extendBody: true`) — or ZERO when there is no dock above it.
  ///
  /// The handoff's 120 is measured on a 390×844 frame with no gesture bar. On a
  /// real device the dock is pushed up by the bottom safe area, so that much is
  /// added on top — otherwise the last row hides behind the capsule on exactly
  /// the phones that have a gesture pill.
  ///
  /// The ancestor check is what makes this safe to call anywhere. Settings'
  /// sub-screens (notifications, premium, refer, upload) are pushed OVER the
  /// shell, so they have no [AppShell] ancestor and get 0; a flat 120 left a
  /// screen's worth of dead space at the bottom of those. Callers should not
  /// have to know which way they were opened.
  static double dockClearance(BuildContext context) {
    if (context.findAncestorWidgetOfExactType<AppShell>() == null) return 0;
    return ArulTokens.listBottomInsetUnderDock +
        MediaQuery.viewPaddingOf(context).bottom;
  }

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  @override
  void initState() {
    super.initState();
    // Warm the ringtone catalog once the first frame is up, so the Ringtones
    // tab opens onto a ready list instead of paying its CDN drain on first
    // tap (measured ~5 s cold). Post-frame keeps it off the launch-critical
    // path; the shell only mounts after auth, and the drain is a few KB of
    // edge-cached JSON. Read-only: the provider is keepAlive, its own
    // offline-recheck ladder owns every failure mode, and the tab's normal
    // loading/error states still cover a drain that is slow or still failing
    // when the user arrives.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(ringtoneCatalogProvider);
    });
  }

  @override
  void didUpdateWidget(covariant AppShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    final from = oldWidget.navigationShell.currentIndex;
    final to = widget.navigationShell.currentIndex;
    if (from == to) return;

    if (from == AppShell.wallpapersBranch) {
      // Fire-and-forget: the pool's own epoch guard makes a release racing a
      // quick return safe (reclaim reconciles from scratch).
      unawaited(ref.read(videoPreloadControllerProvider).releaseDecoders());
    }
    if (to == AppShell.wallpapersBranch) {
      ref.read(videoPreloadControllerProvider).reclaimDecoders();
    }
    if (from == AppShell.ringtonesBranch) {
      unawaited(ref.read(ringtonePreviewProvider.notifier).stop());
    }
  }

  void _onTap(int index) {
    // A tab picks between values, so it ticks rather than presses. Re-tapping
    // the active tab stays silent — nothing changed.
    if (index != widget.navigationShell.currentIndex) {
      ArulHaptics.selection();
    }
    widget.navigationShell.goBranch(
      index,
      // Re-tapping the active tab pops that branch to its root (stock shell
      // idiom) — a no-op here since each branch is a single screen.
      initialLocation: index == widget.navigationShell.currentIndex,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      // The dock FLOATS: the branch content runs full-bleed behind it and
      // scrolls under the capsule (the island treatment).
      extendBody: true,
      body: widget.navigationShell,
      bottomNavigationBar: ArulNavDock(
        currentIndex: widget.navigationShell.currentIndex,
        onTap: _onTap,
        items: [
          // "Settings" is the screen's own title in every locale — the tab and
          // the screen are the same word, so it shares one ARB key.
          (glyph: ArulLineGlyph.wallpapers, label: l10n.tabWallpapers),
          (glyph: ArulLineGlyph.ringtones, label: l10n.tabRingtones),
          (glyph: ArulLineGlyph.settings, label: l10n.settingsTitle),
        ],
      ),
    );
  }
}

/// One dock tab's content.
typedef ArulNavItem = ({ArulLineGlyph glyph, String label});

// ─── Branch crossfade ─────────────────────────────────────────────────────────

/// Cross-fades between the branches over [ArulTokens.tabSwitch] instead of
/// cutting between them.
///
/// `StatefulShellRoute.indexedStack` swaps branches on a single frame, which on
/// this app is a hard cut from a playing video reel to a list of cards — the
/// jump the eye notices most. Pakiza cross-fades, and this is that container.
///
/// It is careful about what a fade normally costs:
///
///   * every branch stays MOUNTED, so each tab keeps its own scroll position
///     (the whole reason for a stateful shell);
///   * only the incoming and outgoing branches are [Offstage]-visible, so an
///     idle branch is laid out but never painted;
///   * `TickerMode` is off for everything but the current branch, so the feed's
///     animations — and the ringtone diya's flicker — stop dead on a hidden
///     tab rather than burning frames behind one.
class ArulBranchCrossfade extends StatefulWidget {
  const ArulBranchCrossfade({
    super.key,
    required this.currentIndex,
    required this.children,
  });

  final int currentIndex;
  final List<Widget> children;

  @override
  State<ArulBranchCrossfade> createState() => _ArulBranchCrossfadeState();
}

class _ArulBranchCrossfadeState extends State<ArulBranchCrossfade>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: ArulTokens.tabSwitch,
    value: 1,
  );
  late int _previous = widget.currentIndex;

  @override
  void didUpdateWidget(covariant ArulBranchCrossfade old) {
    super.didUpdateWidget(old);
    if (widget.currentIndex != old.currentIndex) {
      _previous = old.currentIndex;
      _c.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) => Stack(
        children: [
          for (var i = 0; i < widget.children.length; i++) _branch(i, _c.value),
        ],
      ),
    );
  }

  Widget _branch(int i, double t) {
    final isCurrent = i == widget.currentIndex;
    final isOutgoing = i == _previous && t < 1;
    final opacity = isCurrent ? t : (isOutgoing ? 1 - t : 0.0);

    return Offstage(
      offstage: !isCurrent && !isOutgoing,
      child: IgnorePointer(
        ignoring: !isCurrent,
        child: TickerMode(
          enabled: isCurrent,
          child: Opacity(
            opacity: opacity.clamp(0, 1),
            child: widget.children[i],
          ),
        ),
      ),
    );
  }
}

/// The floating island dock — a detached capsule hovering above the bottom
/// edge; branch content scrolls full-bleed behind it (Scaffold.extendBody).
///
/// Every tab shows its icon AND its label; the active one sits in a
/// gold-tinted rounded cell that simply moves between tabs rather than gliding.
/// That is deliberate: the previous dock slid a solid pill and revealed the
/// label only on the active side, which made the two inactive tabs read as
/// unlabelled glyphs and put a moving object under the user's thumb. Three
/// tabs need names.
///
/// Paint-only, no blur: the handoff asks for `backdrop-blur 14`, but
/// `BackdropFilter` costs ~6–9 ms of raster per frame on mid-tier Android and
/// this capsule sits over a playing video feed (docs/ui-direction.md > Perf).
/// The opaque [ArulTokens.dockFillDark] carries the same separation.
///
/// Behind the capsule is a vertical fade to the screen's own surface — Pakiza's
/// treatment, and the reason its dock does not look see-through. Without it,
/// content keeps scrolling past in the 18px side channels and the 14px below
/// the capsule, so the eye reads a bar with rows sliding out from under it. The
/// fade dissolves that content instead of slicing it. It absorbs no touches, so
/// a drag that starts in the transparent zone still scrolls the list.
class ArulNavDock extends StatelessWidget {
  const ArulNavDock({
    super.key,
    required this.currentIndex,
    required this.onTap,
    required this.items,
  });

  final int currentIndex;
  final ValueChanged<int> onTap;
  final List<ArulNavItem> items;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final surface = isDark ? ArulTokens.darkSurface : ArulTokens.ivory;

    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          // Fade to the SURFACE's own alpha-0, never Colors.transparent — that
          // is transparent black, and lerping through it drags the fade toward
          // a grey smear on the ivory theme.
          colors: [
            surface.withValues(alpha: 0),
            surface.withValues(alpha: ArulTokens.dockScrimAlpha),
            surface.withValues(alpha: ArulTokens.dockScrimAlpha),
          ],
          stops: const [0, ArulTokens.dockScrimStop, 1],
        ),
      ),
      child: SafeArea(
        top: false,
        minimum: const EdgeInsets.only(bottom: ArulTokens.dockBottomInset),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: ArulTokens.dockSideInset,
          ),
          // The pane is a fixed height with fixed-size labels, so an unclamped
          // system font scale (2x on Android) would burst it. Same clamp Pakiza
          // puts on its dock, and the same reason.
          child: MediaQuery.withClampedTextScaling(
            maxScaleFactor: 1.1,
            child: Container(
              height: ArulTokens.dockHeight,
              padding: const EdgeInsets.symmetric(
                horizontal: ArulTokens.dockInnerPadding,
              ),
              decoration: BoxDecoration(
                color: isDark
                    ? ArulTokens.dockFillDark
                    : ArulTokens.cardBgLight,
                borderRadius: BorderRadius.circular(ArulTokens.dockRadius),
                border: Border.all(
                  color: isDark
                      ? ArulTokens.cardBorderDark08
                      : ArulTokens.maroonBorder08,
                ),
                boxShadow: isDark
                    ? ArulTokens.dockShadowDark
                    : ArulTokens.dockShadowLight,
              ),
              child: Row(
                children: [
                  for (var i = 0; i < items.length; i++)
                    Expanded(
                      child: _DockTab(
                        item: items[i],
                        selected: i == currentIndex,
                        onTap: () => onTap(i),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DockTab extends StatelessWidget {
  const _DockTab({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final ArulNavItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Active reads as a lit cell: gold ink on a gold tint in the dark, and dark
    // ink on solid pale gold in the light (gold-on-gold would vanish there).
    final Color fg;
    if (selected) {
      fg = isDark ? ArulTokens.gold : ArulTokens.lightText;
    } else {
      fg = isDark ? ArulTokens.darkMuted : ArulTokens.lightSecondary;
    }

    return Semantics(
      button: true,
      selected: selected,
      label: item.label,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          height: ArulTokens.dockTabHeight,
          decoration: selected
              ? BoxDecoration(
                  color: isDark
                      ? ArulTokens.goldTintFill13
                      : ArulTokens.dockActiveFillLight,
                  borderRadius: BorderRadius.circular(
                    ArulTokens.dockActiveTabRadius,
                  ),
                  border: Border.all(
                    color: isDark
                        ? ArulTokens.goldBorder45
                        : ArulTokens.goldBorder50,
                  ),
                  // No halo. The handoff puts a 20px gold glow here; on a real
                  // panel it fogged the cell's edge and made the dark theme
                  // look hazy. Fill + rim already say "active".
                )
              : null,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ArulLineIcon(
                glyph: item.glyph,
                size: ArulTokens.dockIconSize,
                color: fg,
              ),
              const SizedBox(height: ArulTokens.dockTabGap),
              // The cell is a fixed 58 inside a fixed 78 capsule, so a label at
              // a 2× OS font size would overflow it. Flexible lets the Column
              // hand it less room; scaleDown then fits the type into whatever
              // room it got, instead of breaking the dock.
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    item.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style:
                        (selected
                                ? ArulTokens.dockLabelActive
                                : ArulTokens.dockLabel)
                            .copyWith(color: fg),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
