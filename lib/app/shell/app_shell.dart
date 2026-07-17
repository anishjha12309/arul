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
      body: widget.navigationShell,
      bottomNavigationBar: _ArulNavBar(
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

/// Hand-rolled bottom bar (NOT the stock NavigationBar): the app's dark frame
/// with a hairline top border; the active item sits in an animated gold pill —
/// the same selection language as the chips and premium badging. Transform/
/// opacity/paint only, no blur, no elevation (docs/ui-direction.md).
class _ArulNavBar extends StatelessWidget {
  const _ArulNavBar({
    required this.currentIndex,
    required this.onTap,
    required this.items,
  });

  final int currentIndex;
  final ValueChanged<int> onTap;
  final List<_NavItem> items;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? ArulTokens.darkSurface : ArulTokens.ivory;
    final hairline = isDark
        ? ArulTokens.cardBorderDark14
        : ArulTokens.cardBorderLight;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: bg,
        border: Border(top: BorderSide(color: hairline)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 60,
          child: Row(
            children: [
              for (var i = 0; i < items.length; i++)
                Expanded(
                  child: _NavBarItem(
                    item: items[i],
                    selected: i == currentIndex,
                    onTap: () => onTap(i),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavBarItem extends StatelessWidget {
  const _NavBarItem({
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

    // Gold selection on the dark frame, maroon on ivory — the app's standard
    // accent split.
    final activeFg = isDark ? ArulTokens.gold : ArulTokens.maroon;
    final inactiveFg = isDark
        ? ArulTokens.darkMuted
        : ArulTokens.lightSecondary;
    final pillFill = isDark
        ? ArulTokens.goldTintFill14
        : ArulTokens.maroonTintFill08;
    final pillBorder = isDark
        ? ArulTokens.goldBorder35
        : ArulTokens.maroonBorder18;

    return Semantics(
      button: true,
      selected: selected,
      label: item.label,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Center(
          child: AnimatedContainer(
            duration: ArulTokens.chromeSettleIn,
            curve: ArulTokens.settleCurve,
            padding: EdgeInsets.symmetric(
              horizontal: selected ? 16 : 10,
              vertical: 8,
            ),
            decoration: BoxDecoration(
              color: selected ? pillFill : pillFill.withValues(alpha: 0),
              borderRadius: BorderRadius.circular(ArulTokens.pillRadius),
              border: Border.all(
                color: selected ? pillBorder : pillBorder.withValues(alpha: 0),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  item.icon,
                  size: 20,
                  color: selected ? activeFg : inactiveFg,
                ),
                // The label rides only in the active pill — the inactive item
                // is a quiet glyph, so the bar stays low and unlabeled space
                // never fights the reel below it.
                AnimatedSize(
                  duration: ArulTokens.chromeSettleIn,
                  curve: ArulTokens.settleCurve,
                  child: selected
                      ? Padding(
                          padding: const EdgeInsets.only(left: 7),
                          child: Text(
                            item.label,
                            maxLines: 1,
                            style: ArulTokens.chipActive.copyWith(
                              color: activeFg,
                            ),
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
