import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/ringtones/providers/ringtone_preview_provider.dart';
import '../../features/wallpapers/providers/video_preload_provider.dart';
import '../../theme/arul_tokens.dart';
import '../l10n/app_localizations.dart';

/// The tabbed scaffold around the two browse surfaces (Wallpapers /
/// Ringtones). Everything else — settings, refer, upload, premium — pushes
/// OVER this shell as a full-screen route.
///
/// The [StatefulShellRoute.indexedStack] keeps BOTH branches alive, which is
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

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
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
    if (index != widget.navigationShell.currentIndex) {
      HapticFeedback.lightImpact();
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
      bottomNavigationBar: _ArulNavDock(
        currentIndex: widget.navigationShell.currentIndex,
        onTap: _onTap,
        items: [
          _NavItem(icon: Icons.wallpaper_outlined, label: l10n.tabWallpapers),
          _NavItem(icon: Icons.music_note_outlined, label: l10n.tabRingtones),
        ],
      ),
    );
  }
}

class _NavItem {
  const _NavItem({required this.icon, required this.label});
  final IconData icon;
  final String label;
}

/// The floating island dock — a detached capsule hovering above the bottom
/// edge; branch content scrolls full-bleed behind it (Scaffold.extendBody).
///
/// Statement treatment, paint-only (no blur / shaders — ui-direction.md):
///   * dark capsule with a gold hairline rim and a warm drop shadow;
///   * a SOLID gold pill glides between the two halves ([AnimatedAlign]) with
///     a soft diya-glow (gold [BoxShadow]);
///   * the label reveals only on the active side; inactive is a quiet glyph.
class _ArulNavDock extends StatelessWidget {
  const _ArulNavDock({
    required this.currentIndex,
    required this.onTap,
    required this.items,
  });

  final int currentIndex;
  final ValueChanged<int> onTap;
  final List<_NavItem> items;

  static const double _height = 64;
  static const double _pillInset = 6;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final capsule = isDark
        ? ArulTokens.darkSheetSurface
        : ArulTokens.cardBgLight;
    final rim = isDark ? ArulTokens.goldBorder35 : ArulTokens.maroonBorder18;
    final pill = isDark ? ArulTokens.gold : ArulTokens.maroon;
    final glow = isDark
        ? ArulTokens.gold.withValues(alpha: 0.30)
        : ArulTokens.maroon.withValues(alpha: 0.22);

    // -1 → left half, 1 → right half (two tabs).
    final align = Alignment(currentIndex == 0 ? -1.0 : 1.0, 0);

    return SafeArea(
      top: false,
      minimum: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 4),
        child: Container(
          height: _height,
          decoration: BoxDecoration(
            color: capsule,
            borderRadius: BorderRadius.circular(ArulTokens.pillRadius),
            border: Border.all(color: rim),
            boxShadow: [
              // Grounding shadow so the island reads as floating over the reel.
              BoxShadow(
                color: ArulTokens.darkSurface.withValues(alpha: 0.55),
                blurRadius: 22,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.all(_pillInset),
            child: Stack(
              children: [
                // The gliding gold pill + its diya glow.
                AnimatedAlign(
                  alignment: align,
                  duration: ArulTokens.chromeSettleIn,
                  curve: ArulTokens.settleCurve,
                  child: FractionallySizedBox(
                    widthFactor: 0.5,
                    heightFactor: 1,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: pill,
                        borderRadius: BorderRadius.circular(
                          ArulTokens.pillRadius,
                        ),
                        boxShadow: [BoxShadow(color: glow, blurRadius: 16)],
                      ),
                      child: const SizedBox.expand(),
                    ),
                  ),
                ),
                Row(
                  children: [
                    for (var i = 0; i < items.length; i++)
                      Expanded(
                        child: _DockItem(
                          item: items[i],
                          selected: i == currentIndex,
                          onTap: () => onTap(i),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DockItem extends StatelessWidget {
  const _DockItem({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final _NavItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Content over the gold pill is surface-dark (ink on gold — the selected
    // chip's grammar); inactive is a lone muted glyph.
    final activeFg = isDark ? ArulTokens.darkSurface : ArulTokens.ivory;
    final inactiveFg = isDark
        ? ArulTokens.darkMuted
        : ArulTokens.lightSecondary;
    final fg = selected ? activeFg : inactiveFg;

    return Semantics(
      button: true,
      selected: selected,
      label: item.label,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(item.icon, size: 20, color: fg),
              // Label reveals only while this side is active; the glide and
              // the reveal share one clock so the pill never outruns its text.
              AnimatedSize(
                duration: ArulTokens.chromeSettleIn,
                curve: ArulTokens.settleCurve,
                child: selected
                    ? Padding(
                        padding: const EdgeInsets.only(left: 7),
                        child: Text(
                          item.label,
                          maxLines: 1,
                          style: ArulTokens.chipActive.copyWith(color: fg),
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
