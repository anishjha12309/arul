import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/analytics/analytics_provider.dart';
import '../../core/deeplink/deep_link_target.dart';
import '../../core/haptics/arul_haptics.dart';
import '../../features/ringtones/providers/ringtone_catalog_providers.dart';
import '../../features/ringtones/providers/ringtone_preview_provider.dart';
import '../../features/wallpapers/providers/video_preload_provider.dart';
import '../../theme/arul_tokens.dart';
import '../l10n/app_localizations.dart';
import '../widgets/arul_line_icons.dart';
import '../widgets/english_only.dart';

/// The tabbed scaffold around Wallpapers / Ringtones / Settings — everything else pushes OVER it.
///
/// The stateful shell keeps every branch ALIVE -> hidden media never tears itself down -> referee:
///
///   * leaving Wallpapers -> `releaseDecoders()`: budget SoCs hold a handful, and a hidden feed must
///     never keep playing behind the ringtone list;
///   * returning -> `reclaimDecoders()` reconciles onto the current page; list and index live in the
///     app-scoped controller;
///   * leaving Ringtones -> preview audio stops; the screen's own route listener double-stops, idempotently.
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  static const int wallpapersBranch = 0;
  static const int ringtonesBranch = 1;
  static const int settingsBranch = 2;

  /// Bottom padding a scrollable owes the floating dock it runs under — 0 when there is no dock.
  ///
  /// The handoff's 120 assumes a 390×844 frame with no gesture bar -> add the bottom safe area on top.
  /// Otherwise the last row hides behind the capsule on exactly the phones that have a gesture pill.
  /// Sub-screens pushed OVER the shell have no [AppShell] ancestor -> 0, not a flat 120 of dead space.
  /// So the ancestor check is what makes this safe to call without knowing how the screen was opened.
  static double dockClearance(BuildContext context) {
    if (context.findAncestorWidgetOfExactType<AppShell>() == null) return 0;
    return ArulTokens.listBottomInsetUnderDock +
        MediaQuery.viewPaddingOf(context).bottom;
  }

  /// The dock branch a deep-link target lives on.
  static int branchFor(ArulTab tab) => switch (tab) {
    ArulTab.wallpapers => wallpapersBranch,
    ArulTab.ringtones => ringtonesBranch,
  };

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  @override
  void initState() {
    super.initState();
    // A first tap on Ringtones paid a ~5 s cold CDN drain -> warm the catalog once a frame is up.
    // Post-frame keeps it off the launch-critical path; the shell only mounts after auth.
    // Read-only: the provider is keepAlive and its own offline-recheck ladder owns every failure.
    // The tab's loading/error states still cover a drain that is slow or failing when the user lands.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(ringtoneCatalogProvider);
    });
    // A link decides which tab the shell opens on -> check once here; a target can be parked pre-sign-in.
    // GA4F and the Meta SDK deliver mid-startup and an App Link can land warm -> listen for later ones.
    ArulDeepLink.changes.addListener(_onDeepLinkChanged);
    _onDeepLinkChanged();
  }

  @override
  void dispose() {
    ArulDeepLink.changes.removeListener(_onDeepLinkChanged);
    super.dispose();
  }

  /// Written from go_router's redirect, and `goBranch` must not navigate during a build -> microtask.
  void _onDeepLinkChanged() => scheduleMicrotask(_followDeepLink);

  /// Switch to the branch the pending target lives on.
  ///
  /// A wallpaper/ringtone target is only PEEKED -> the tab's screen consumes it once it resolves the id.
  /// A tab-only target (`screen=ringtones`, no id) has nothing further to show -> consumed on the switch.
  void _followDeepLink() {
    if (!mounted) return;
    final target = ArulDeepLink.pendingTarget;
    if (target == null) return;
    if (target is TabLinkTarget) {
      ArulDeepLink.consumeTab();
      ref
          .read(analyticsServiceProvider)
          .track('deep_link_opened', properties: target.analyticsProperties);
    }
    final branch = AppShell.branchFor(target.tab);
    if (widget.navigationShell.currentIndex != branch) {
      widget.navigationShell.goBranch(branch);
    }
  }

  @override
  void didUpdateWidget(covariant AppShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    final from = oldWidget.navigationShell.currentIndex;
    final to = widget.navigationShell.currentIndex;
    if (from == to) return;

    if (from == AppShell.wallpapersBranch) {
      // The pool's epoch guard makes a release racing a quick return safe -> fire-and-forget.
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
    // A tab picks between values -> it ticks, never presses; re-tapping the active tab stays silent.
    if (index != widget.navigationShell.currentIndex) {
      ArulHaptics.selection();
    }
    widget.navigationShell.goBranch(
      index,
      // Re-tapping the active tab pops that branch to its root — a no-op while each branch is one screen.
      initialLocation: index == widget.navigationShell.currentIndex,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // The dock FLOATS -> branch content runs full-bleed behind it and scrolls under the capsule.
      extendBody: true,
      body: widget.navigationShell,
      // `tabRingtones` is demoted (EnglishOnly doc) -> one English tab among translated ones read as
      // a defect -> the whole dock is English.
      // The Builder is what puts the label lookup UNDER the override.
      bottomNavigationBar: EnglishOnly(
        child: Builder(
          builder: (context) {
            final en = AppLocalizations.of(context);
            return ArulNavDock(
              currentIndex: widget.navigationShell.currentIndex,
              onTap: _onTap,
              items: [
                // Tab and screen are the same word -> one ARB key; only the tab reads it overridden.
                (glyph: ArulLineGlyph.wallpapers, label: en.tabWallpapers),
                (glyph: ArulLineGlyph.ringtones, label: en.tabRingtones),
                (glyph: ArulLineGlyph.settings, label: en.settingsTitle),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// One dock tab's content.
typedef ArulNavItem = ({ArulLineGlyph glyph, String label});

/// Cross-fades between branches over [ArulTokens.tabSwitch] instead of cutting between them.
///
/// `indexedStack` swaps branches on ONE frame -> a hard cut from a playing reel to a list of cards.
///
///   * every branch stays MOUNTED -> each tab keeps its own scroll position;
///   * only the incoming and outgoing branches are [Offstage]-visible -> an idle branch never paints;
///   * `TickerMode` is off outside the current branch -> hidden animations stop, never burn frames.
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

/// The floating island dock — a detached capsule; branch content scrolls full-bleed behind it.
///
/// Three tabs need names -> every tab shows icon AND label, and the active cell moves, never glides.
/// A label on the active side only made the other two read as unlabelled glyphs under a sliding pill.
/// `BackdropFilter` costs ~6–9 ms of raster per frame on mid-tier Android, over a live video feed.
/// So no blur -> the opaque [ArulTokens.dockFillDark] carries the same separation (ui-direction > Perf).
/// Without a fade behind the capsule, rows keep scrolling in the 18px side channels and 14px below.
/// The eye reads that as a bar with rows sliding out from under it -> fade to the surface's own colour.
/// The fade absorbs no touches -> a drag starting in the transparent zone still scrolls the list.
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
          // Colors.transparent is transparent BLACK -> lerping through it greys the ivory fade.
          // So fade to the SURFACE's own alpha-0, never Colors.transparent.
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
          // Fixed height, fixed-size labels -> an unclamped 2x system font scale bursts the pane.
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

    // Active is a lit cell: gold ink on a gold tint in the dark.
    // Gold-on-gold would vanish on the light theme -> dark ink on solid pale gold there instead.
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
                  // The handoff's 20px gold glow fogged the cell edge and hazed
                  // the dark theme -> no halo; fill and rim already say active.
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
              // A fixed 58 cell inside a fixed 78 capsule -> a 2× OS font size overflows the label.
              // Flexible hands it less room and scaleDown fits the type to that -> the dock never breaks.
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
