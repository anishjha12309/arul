import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/analytics/analytics_provider.dart';
import '../../core/deeplink/deep_link_target.dart';
import '../../core/haptics/arul_haptics.dart';
import '../../features/ringtones/providers/ringtone_catalog_providers.dart';
import '../../features/ringtones/providers/ringtone_preview_provider.dart';
import '../../features/status/providers/status_providers.dart';
import '../../features/wallpapers/providers/video_preload_provider.dart';
import '../../theme/arul_tokens.dart';
import '../l10n/app_localizations.dart';
import '../theme/motion.dart';
import '../widgets/arul_line_icons.dart';
import '../widgets/reel/reel_item.dart';
import '../widgets/reel/video_preload_controller.dart';
import 'shell_route_observer.dart';

/// The tabbed scaffold around Wallpapers / Ringtones / Status — everything else, Settings included,
/// pushes OVER it.
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  // Branch index = dock index = position in router.dart's `branches` -> keep the three in step.
  static const int wallpapersBranch = 0;
  static const int ringtonesBranch = 1;
  static const int statusBranch = 2;

  /// Bottom padding a scrollable owes the floating dock it runs under — 0 when there is no dock.
  /// The handoff's 120 assumes a 390×844 frame with no gesture bar -> add the bottom safe area on top.
  /// Otherwise the last row hides behind the capsule on exactly the phones that have a gesture pill.
  static double dockClearance(BuildContext context) {
    if (context.findAncestorWidgetOfExactType<AppShell>() == null) return 0;
    return ArulTokens.listBottomInsetUnderDock +
        MediaQuery.viewPaddingOf(context).bottom;
  }

  static int branchFor(ArulTab tab) => switch (tab) {
    ArulTab.wallpapers => wallpapersBranch,
    ArulTab.ringtones => ringtonesBranch,
    ArulTab.status => statusBranch,
  };

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> with RouteAware {
  PageRoute<dynamic>? _route;

  /// A full screen is pushed over the shell -> no reel underneath may decode or play.
  bool _covered = false;

  /// Bumped per Wallpapers<->Status swap -> a swap overtaken during its await never reclaims.
  int _swapSeq = 0;

  /// This shell's number, for [ArulDeepLink.mayTake].
  final int _shell = ArulDeepLink.registerShell();

  /// What [ArulShellScope] tells the branch screens: 0 until this shell has picked the branch for a
  /// pending link -> a screen moved in from the outgoing shell cannot take it before the switch.
  int _scopeShell = 0;

  void _openScope() {
    if (!mounted || _scopeShell == _shell) return;
    setState(() => _scopeShell = _shell);
  }

  @override
  void initState() {
    super.initState();
    // Post-frame keeps it off the launch-critical path; the shell only mounts after auth.
    // Read-only: the provider is keepAlive and its own offline-recheck ladder owns every failure.
    // The tab's loading/error states still cover a drain that is slow or failing when the user lands.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(ringtoneCatalogProvider);
      // A push tap can open the shell straight onto Status -> no switch ever runs to show its reel.
      // The reels are app-scoped, so a REBUILT shell (sign-out and back, a paywall `go`) inherits the
      // hidden flag the feed got when it was covered -> restate it, or every live card stays a poster.
      final index = widget.navigationShell.currentIndex;
      if (index == AppShell.statusBranch ||
          (index == AppShell.wallpapersBranch &&
              !ref.read(videoPreloadControllerProvider).visible)) {
        unawaited(_enterReel(index));
      }
    });
    // A link decides which tab the shell opens on -> check once here; a target can be parked pre-sign-in.
    // GA4F and the Meta SDK deliver mid-startup and an App Link can land warm -> listen for later ones.
    ArulDeepLink.changes.addListener(_onDeepLinkChanged);
    _onDeepLinkChanged();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute<dynamic> && route != _route) {
      if (_route != null) shellRouteObserver.unsubscribe(this);
      _route = route;
      shellRouteObserver.subscribe(this, route);
    }
  }

  @override
  void dispose() {
    shellRouteObserver.unsubscribe(this);
    ArulDeepLink.changes.removeListener(_onDeepLinkChanged);
    super.dispose();
  }

  /// The reel a branch shows, or null for a branch without video.
  VideoPreloadController<ReelItem>? _reelFor(int branch) => switch (branch) {
    AppShell.wallpapersBranch => ref.read(videoPreloadControllerProvider),
    AppShell.statusBranch => ref.read(statusVideoControllerProvider),
    _ => null,
  };

  /// Settings, the paywall, upload or a policy went over the shell: the reel stops now and frees
  /// its decoders after the same grace as a tab leave — Back is the trip most likely undone.
  @override
  void didPushNext() {
    _covered = true;
    final reel = _reelFor(widget.navigationShell.currentIndex);
    if (reel == null) return;
    reel.visible = false;
    reel.releaseDecodersOnLeave();
  }

  @override
  void didPopNext() {
    _covered = false;
    final reel = _reelFor(widget.navigationShell.currentIndex);
    if (reel == null) return;
    reel
      ..visible = true
      ..reclaimDecoders();
  }

  /// Written from go_router's redirect, and `goBranch` must not navigate during a build -> microtask.
  void _onDeepLinkChanged() => scheduleMicrotask(_followDeepLink);

  /// A wallpaper/ringtone target is only PEEKED -> the tab's screen consumes it once it resolves the id.
  /// A tab-only target (`screen=ringtones`, no id) has nothing further to show -> consumed on the switch.
  void _followDeepLink() {
    if (!mounted) return;
    if (!ArulDeepLink.mayTake(_shell)) return;
    final target = ArulDeepLink.pendingTarget;
    if (target == null) {
      _openScope();
      return;
    }
    if (target is TabLinkTarget) {
      ArulDeepLink.consumeTab(shell: _shell);
      ref
          .read(analyticsServiceProvider)
          .track('deep_link_opened', properties: target.analyticsProperties);
    }
    final branch = AppShell.branchFor(target.tab);
    if (widget.navigationShell.currentIndex != branch) {
      widget.navigationShell.goBranch(branch);
    }
    _openScope();
  }

  /// Two pools never decode at once: the OTHER reel is released IN FULL before the entering one
  /// claims a session, with no grace — whether it was left on this switch or is still inside an
  /// earlier leave's grace (a hop through Ringtones). Budget SoCs hold about two hardware decoders.
  Future<void> _enterReel(int to) async {
    final seq = ++_swapSeq;
    final entering = _reelFor(to);
    if (entering == null) return;
    // Never build the status controller just to release it.
    final other = to == AppShell.statusBranch
        ? _reelFor(AppShell.wallpapersBranch)
        : ref.exists(statusVideoControllerProvider)
        ? _reelFor(AppShell.statusBranch)
        : null;
    if (other != null) {
      other.visible = false;
      await other.releaseDecoders();
    }
    if (!mounted || seq != _swapSeq || _covered) return;
    entering
      ..visible = true
      ..reclaimDecoders();
  }

  @override
  void didUpdateWidget(covariant AppShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    final from = oldWidget.navigationShell.currentIndex;
    final to = widget.navigationShell.currentIndex;
    if (from == to) return;

    if (to == AppShell.wallpapersBranch || to == AppShell.statusBranch) {
      unawaited(_enterReel(to));
    } else {
      _swapSeq++;
      final leaving = _reelFor(from);
      if (leaving != null) {
        leaving.visible = false;
        // The pool's epoch guard makes a release racing a quick return safe -> fire-and-forget.
        leaving.releaseDecodersOnLeave();
      }
    }
    if (from == AppShell.ringtonesBranch || to == AppShell.statusBranch) {
      // `stop()` writes the notifier's state at once, and didUpdateWidget runs INSIDE a build ->
      // Riverpod refuses a provider write mid-build (a debug assert; in release the write lands
      // while dependents are half-built). One microtask later is after this frame's build phase and
      // before its paint, so the preview still stops before the branch is out of sight.
      Future.microtask(() {
        if (!mounted) return;
        unawaited(ref.read(ringtonePreviewProvider.notifier).stop());
      });
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
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      extendBody: true,
      body: ArulShellScope(shell: _scopeShell, child: widget.navigationShell),
      bottomNavigationBar: ArulNavDock(
        currentIndex: widget.navigationShell.currentIndex,
        onTap: _onTap,
        items: [
          // Tab and screen are the same word -> one ARB key for both.
          (glyph: ArulLineGlyph.wallpapers, label: l10n.tabWallpapers),
          (glyph: ArulLineGlyph.ringtones, label: l10n.tabRingtones),
          (glyph: ArulLineGlyph.status, label: l10n.statusTitle),
        ],
      ),
    );
  }
}

typedef ArulNavItem = ({ArulLineGlyph glyph, String label});

/// Cross-fades between branches over [ArulTokens.tabSwitch] instead of cutting between them.
/// `indexedStack` swaps branches on ONE frame -> a hard cut from a playing reel to a list of cards.
///   * only the incoming and outgoing branches are [Offstage]-visible -> an idle branch never paints;
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
      if (context.reduceMotion) {
        _c.value = 1;
      } else {
        _c.forward(from: 0);
      }
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

/// Every tab shows icon AND label, and the active cell moves, never glides.
/// A label on the active side only made the others read as unlabelled glyphs under a sliding pill.
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
      onTap: onTap,
      // The GLYPH names the tab, not the label: the dock's labels are ARB strings and an
      // accessibility id must not move when one is reworded.
      identifier: 'arul_tab_${item.glyph.name}',
      // The label is the visible word underneath -> without this it is announced twice.
      excludeSemantics: true,
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
