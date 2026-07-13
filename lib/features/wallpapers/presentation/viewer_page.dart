import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/l10n/app_localizations.dart';
import '../../../app/theme/scrims.dart';
import '../../../app/theme/typography.dart';
import '../../../app/theme/tokens.dart';
import '../../../data/models/wallpaper.dart';

/// One full-screen viewer page: the media, plus the chrome that can be dismissed.
///
/// No RepaintBoundary at the root and NO keep-alive: PageView.builder already
/// wraps every child in a RepaintBoundary, and a keep-alive would pin this page's
/// decoded image and video texture in memory for the life of the pager — the
/// classic way a media pager gets OOM-killed on a 2 GB device.
class ViewerPage extends StatelessWidget {
  const ViewerPage({
    super.key,
    required this.wallpaper,
    required this.media,
    required this.chromeVisible,
    required this.busy,
    required this.onToggleChrome,
    required this.onApply,
    required this.onShare,
  });

  final Wallpaper wallpaper;
  final Widget media;
  final bool chromeVisible;
  final bool busy;
  final VoidCallback onToggleChrome;
  final VoidCallback? onApply;
  final VoidCallback? onShare;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    // NOT Theme.of(context).textTheme. That scale's muted tier is a luminance a
    // gradient scrim cannot pay for: over a bright wallpaper it measures 2.4:1,
    // and no scrim strong enough to fix it is one worth having (it would just be
    // a grey box over the product). Over media, hierarchy comes from size and
    // tracking; the colour stays white.
    final type = ArulType.onMedia();
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;
    final topInset = MediaQuery.viewPaddingOf(context).top;

    // The title is only worth its pixels when it says something the category has
    // not already said. Many catalog items have no subject name, so the model
    // falls back title = categoryName — which rendered a pill reading "TEMPLES"
    // directly above a heading reading "Temples". That is not information, it is
    // furniture.
    final titleAddsSomething =
        wallpaper.title.trim().toLowerCase() !=
        wallpaper.categoryLabel.trim().toLowerCase();

    return Stack(
      fit: StackFit.expand,
      children: [
        GestureDetector(
          // Tap the media to get the chrome out of the way. Opaque so the tap is
          // caught over the whole page, but it sits UNDER the action buttons, so
          // it never swallows their taps.
          behavior: HitTestBehavior.opaque,
          onTap: onToggleChrome,
          child: media,
        ),

        // All chrome fades as one layer: opacity only, no relayout, and nothing
        // that interrupts the video decoding underneath.
        IgnorePointer(
          ignoring: !chromeVisible,
          child: AnimatedOpacity(
            opacity: chromeVisible ? 1 : 0,
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOut,
            child: Stack(
              fit: StackFit.expand,
              children: [
                // Legibility over arbitrary imagery comes from gradient scrims —
                // ordinary paints. Never a BackdropFilter: it costs 6-9ms of
                // raster per frame, which is the budget the video decoder needs.
                const Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  height: 140,
                  child: DecoratedBox(
                    decoration: BoxDecoration(gradient: ArulScrims.top),
                  ),
                ),
                const Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  height: 260,
                  child: DecoratedBox(
                    decoration: BoxDecoration(gradient: ArulScrims.bottom),
                  ),
                ),

                Positioned(
                  top: topInset + Gap.sm,
                  left: Gap.sm,
                  child: _CircleButton(
                    icon: Icons.arrow_back_rounded,
                    label: MaterialLocalizations.of(context).backButtonTooltip,
                    onTap: () => Navigator.of(context).maybePop(),
                  ),
                ),

                Positioned(
                  left: Gap.lg,
                  right: 88,
                  bottom: bottomInset + Gap.xl,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Text(
                            wallpaper.categoryLabel.toUpperCase(),
                            style: type.labelSmall?.copyWith(letterSpacing: 1.6),
                          ),
                          if (wallpaper.kind == WallpaperKind.live) ...[
                            const SizedBox(width: Gap.sm),
                            Icon(
                              Icons.play_circle_fill_rounded,
                              size: 14,
                              color: Colors.white.withValues(alpha: 0.82),
                              semanticLabel: l10n.feedLiveBadge,
                            ),
                          ],
                        ],
                      ),
                      if (titleAddsSomething) ...[
                        const SizedBox(height: Gap.xs),
                        Text(
                          wallpaper.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: type.headlineSmall,
                        ),
                      ],
                    ],
                  ),
                ),

                Positioned(
                  right: Gap.lg,
                  bottom: bottomInset + Gap.xl,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _CircleButton(
                        icon: Icons.wallpaper_rounded,
                        // Was `MaterialLocalizations.okButtonLabel` — so a screen
                        // reader announced the apply button as "OK", which told a
                        // blind user nothing about what it does.
                        label: l10n.apply,
                        onTap: onApply,
                        emphasised: true,
                      ),
                      const SizedBox(height: Gap.lg),
                      _CircleButton(
                        icon: Icons.ios_share_rounded,
                        label: l10n.share,
                        onTap: onShare,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _CircleButton extends StatelessWidget {
  const _CircleButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.emphasised = false,
  });

  final IconData icon;
  final String label;

  /// Null while an apply or share is in flight — a second tap would start a
  /// second download racing the first for the same temp file.
  final VoidCallback? onTap;
  final bool emphasised;

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null;

    return Semantics(
      button: true,
      enabled: !disabled,
      label: label,
      child: Tooltip(
        message: label,
        child: GestureDetector(
          // A plain GestureDetector, not InkWell: an ink ripple over full-bleed
          // video is invisible anyway, and it would force the Material layer
          // beneath the video to repaint on every tap.
          onTap: disabled
              ? null
              : () {
                  HapticFeedback.lightImpact();
                  onTap!();
                },
          child: Opacity(
            opacity: disabled ? 0.5 : 1,
            child: Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                // Ink, not a theme colour: this floats on arbitrary imagery in
                // both themes and has to defend its own contrast.
                color: ArulColors.mediaFill,
                shape: BoxShape.circle,
                border: Border.all(
                  color: emphasised
                      ? ArulColors.gold
                      : Colors.white.withValues(alpha: 0.28),
                  width: emphasised ? 1.4 : 1,
                ),
              ),
              child: Icon(
                icon,
                size: 24,
                color: emphasised ? ArulColors.gold : Colors.white,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
