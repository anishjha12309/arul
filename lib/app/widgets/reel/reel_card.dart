import 'package:flutter/material.dart';

import '../../../core/haptics/arul_haptics.dart';
import '../../../theme/arul_tokens.dart';
import '../../theme/motion.dart';
import '../gopuram_mark.dart';
import 'feed_card_geometry.dart';
import 'reel_item.dart';
import 'video_preload_controller.dart';

/// The media of one reel page. Listens to the video pool so the page rebinds when the pool
/// reassigns a player to this index; [builder] paints the poster and texture for whatever it holds.
class ReelMedia extends StatelessWidget {
  const ReelMedia({
    super.key,
    required this.controller,
    required this.index,
    required this.builder,
  });

  final VideoPreloadController<ReelItem> controller;
  final int index;
  final Widget Function(BuildContext context, LiveVideoSlot? slot) builder;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => builder(context, controller.slotForIndex(index)),
    );
  }
}

/// A pooled player's texture, fitted like its poster and faded in on its own first frame.
class ReelLiveTexture extends StatelessWidget {
  const ReelLiveTexture({
    super.key,
    required this.slot,
    required this.alignment,
    this.fit = BoxFit.cover,
  });

  final LiveVideoSlot slot;

  /// The crop of the poster underneath -> a texture cropped differently jumps on first frame.
  final Alignment alignment;

  /// The poster's fit, for the same reason as [alignment].
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    // The pool reassigns a player (with its textureId and notifiers) across indices -> keying by
    // index leaves a stale element on another page's texture -> key by playerId.
    return RepaintBoundary(
      key: ValueKey('viewer_video_${slot.playerId}'),
      child: ValueListenableBuilder<bool>(
        // A shared listenable would rebuild siblings on every reveal -> jank while 2-3 players are
        // in flight -> subscribe only to this page's own first-frame flag.
        valueListenable: slot.ready,
        builder: (context, ready, child) => AnimatedOpacity(
          opacity: ready ? 1 : 0,
          // The reveal fades in over the poster; a reassigned player's stale frame CUTS out. Fading
          // it dissolved the last clip into the next card's poster on every chip switch.
          duration: ready && !context.reduceMotion
              ? Motion.imageFade
              : Duration.zero,
          child: child,
        ),
        child: ValueListenableBuilder<Size?>(
          valueListenable: slot.videoSize,
          builder: (context, size, child) {
            if (size == null || size.width <= 0 || size.height <= 0) {
              return const SizedBox.shrink();
            }
            // A raw Texture stretches to its box and never cover-fits itself -> wrap it in
            // FittedBox(cover) over a SizedBox at the video's intrinsic size.
            return ClipRect(
              child: FittedBox(
                fit: fit,
                alignment: alignment,
                clipBehavior: Clip.hardEdge,
                child: SizedBox(
                  width: size.width,
                  height: size.height,
                  child: Texture(textureId: slot.textureId),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Marks the end of a category's reel: the brand gopuram between two hairlines
/// that fade outward, centred in the slot where the next card would otherwise
/// peek. Deliberately quiet — a closing flourish, not a message — so the feed
/// ends the way a book does, and no localized copy is needed.
class ReelEndMark extends StatelessWidget {
  const ReelEndMark({super.key, required this.isDark});

  final bool isDark;

  @override
  Widget build(BuildContext context) {
    // Same accent split as the header's mark: gold on the dark frame, maroon on
    // ivory — muted further because this sits at the feed's quietest edge.
    final accent = isDark ? ArulTokens.gold : ArulTokens.maroon;

    Widget hairline(bool leading) => Container(
      width: 30,
      height: 1,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: leading ? Alignment.centerLeft : Alignment.centerRight,
          end: leading ? Alignment.centerRight : Alignment.centerLeft,
          colors: [accent.withValues(alpha: 0), accent.withValues(alpha: 0.4)],
        ),
      ),
    );

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        hairline(true),
        const SizedBox(width: 12),
        GopuramMark(size: 16, color: accent.withValues(alpha: 0.65)),
        const SizedBox(width: 12),
        hairline(false),
      ],
    );
  }
}

/// Everything that belongs to ONE item, painted inside that item's own card:
/// the bottom scrim, the action row, and an optional mark in the upper field.
///
/// This lives in the page, not in a fixed layer above the pager. A screen-
/// anchored overlay reads like a windshield — the artwork slides past behind
/// controls that never move, and the name of the deity you are looking at has
/// to be swapped in at the right moment by hand (which is what made it lag
/// behind the swipe). Parented to the card, the controls simply ARE part of the
/// wallpaper: they arrive with it, leave with it, and can never describe the
/// wrong one. It also means no fade, no recede, no scroll-notification
/// bookkeeping — the PageView moves them for free.
class ReelCardChrome extends StatelessWidget {
  const ReelCardChrome({super.key, required this.actions, this.mark});

  static const double stackHeight = FeedCardGeometry.scrimHeight;

  static const double _barInset = FeedCardGeometry.actionInset;
  static const double _barInsetH = FeedCardGeometry.actionInset;

  static const double _markInset = 22;

  final ReelActionBar actions;

  /// The ONLY thing in the card's upper field, when there is one.
  final Widget? mark;

  @override
  Widget build(BuildContext context) {
    final mark = this.mark;
    return Stack(
      fit: StackFit.expand,
      children: [
        // IgnorePointer is LOAD-BEARING, not decoration: RenderDecoratedBox
        // overrides hitTestSelf and a BoxDecoration hit-tests true anywhere
        // inside its box. Painted above the media, the scrim would otherwise
        // swallow every touch in the bottom 190 — a swipe started down there
        // would never reach the PageView and the reel would not advance.
        const Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: stackHeight,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(gradient: ArulTokens.feedBottomScrim),
            ),
          ),
        ),

        Positioned(
          left: _barInsetH,
          right: _barInsetH,
          bottom: _barInset,
          child: actions,
        ),

        // Pointer-transparent for the same reason the pill was: a DecoratedBox
        // hit-tests true anywhere in its box, so without this the mark would be
        // a dead zone over the pager.
        if (mark != null)
          Positioned(
            top: _markInset,
            right: _markInset,
            child: IgnorePointer(child: mark),
          ),
      ],
    );
  }
}

/// One verb on a reel card.
class ReelAction {
  const ReelAction({
    required this.icon,
    required this.label,
    required this.semanticsId,
    required this.onTap,
    this.image,
  });

  final IconData icon;

  /// Artwork drawn in place of [icon] in its own colours — a brand mark a person recognises
  /// before reading the label (the WhatsApp logo on the status share).
  final ImageProvider? image;
  final String label;

  /// Stable `Semantics(identifier:)` -> device drivers find the button whatever the locale says.
  final String semanticsId;
  final VoidCallback onTap;
}

/// A reel card's action bar: a wide [primary] pill with a circular [secondary]
/// beside it, centred on the card's lower edge.
/// Colour is deliberately NOT the design system's [ArulTokens.ctaGreen]: that
/// token is for CTAs on THEMED surfaces (sheets, premium, sign-in), where the
/// background is ours. Here the button sits directly on someone's artwork, and
/// the app's established over-media language is ivory + shadow (rail glyphs,
/// meta text, LIVE badge). So the primary is that language in pill form — solid
/// ivory, maroon label — and the secondary is its second weight: the same ivory,
/// held as glass. Hierarchy comes from fill and width, never from a hue that has
/// to win a fight with several hundred devotional wallpapers.
class ReelActionBar extends StatelessWidget {
  const ReelActionBar({
    super.key,
    required this.primary,
    required this.secondary,
    required this.busy,
  });

  static const double height = FeedCardGeometry.actionBarHeight;

  final ReelAction primary;
  final ReelAction secondary;

  /// True while an action is in flight — a second tap would start a second
  /// download racing the first.
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Flexible(
          child: _PrimaryPill(action: primary, enabled: !busy),
        ),
        const SizedBox(width: FeedCardGeometry.actionGap),
        _SecondaryCircle(action: secondary, enabled: !busy),
      ],
    );
  }
}

/// Primary: solid ivory, maroon label. Given a floor width so it reads as the
/// dominant action even where the localized verb is a single short word.
class _PrimaryPill extends StatelessWidget {
  const _PrimaryPill({required this.action, required this.enabled});

  final ReelAction action;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final disabled = !enabled;
    return Semantics(
      button: true,
      enabled: !disabled,
      label: action.label,
      identifier: action.semanticsId,
      child: Opacity(
        opacity: disabled ? 0.55 : 1,
        child: Material(
          color: ArulTokens.ivory,
          borderRadius: BorderRadius.circular(ArulTokens.pillRadius),
          elevation: 0,
          child: InkWell(
            // The primary is one of the card's two commit verbs, so it presses
            // firmer than ordinary chrome. The outcome beat comes separately,
            // from the toast that reports what happened.
            onTapDown: disabled ? null : (_) => ArulHaptics.firm(),
            onTap: disabled ? null : action.onTap,
            borderRadius: BorderRadius.circular(ArulTokens.pillRadius),
            splashColor: ArulTokens.maroonTintFill08,
            highlightColor: ArulTokens.maroonTintFill07,
            // No `alignment:` here — a Container with an alignment expands to
            // its max constraint, which is what stretched the pill across the
            // whole card. Without it the box hugs the label and the minWidth
            // does the rest, so the pill keeps a constant, reference-like width
            // whatever the locale's verb is.
            child: Container(
              height: ReelActionBar.height,
              constraints: const BoxConstraints(
                minWidth: FeedCardGeometry.applyPillMinWidth,
                maxWidth: FeedCardGeometry.applyPillMaxWidth,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 26),
              // Glyph + word (owner's call): a primary action for a low-literacy
              // audience is never a word alone.
              // The ceiling is a hard 240 and the verb may not be cut: at 320dp
              // with the OS at 1.3, Tamil's whole-word "Apply" was ellipsised
              // inside it. So glyph and label shrink TOGETHER to fit the pill
              // they are given, exactly as the sign-in title does — the pill's
              // width is the reference and the type gives way, never the other
              // way round.
              child: Center(
                widthFactor: 1,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _ActionGlyph(
                        action: action,
                        size: 22,
                        color: ArulTokens.maroon,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        action.label,
                        maxLines: 1,
                        textAlign: TextAlign.center,
                        style: ArulTokens.button.copyWith(
                          fontSize: 16,
                          color: ArulTokens.maroon,
                        ),
                      ),
                    ],
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

/// Secondary: the same ivory held as glass — a translucent fill with a hairline
/// border, so it stays readable on white temples and night skies alike without
/// competing with the pill.
class _SecondaryCircle extends StatelessWidget {
  const _SecondaryCircle({required this.action, required this.enabled});

  final ReelAction action;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final disabled = !enabled;
    return Semantics(
      button: true,
      enabled: !disabled,
      label: action.label,
      identifier: action.semanticsId,
      child: Opacity(
        opacity: disabled ? 0.55 : 1,
        child: Material(
          // The over-media glass recipe, shared with the live mark so the card's
          // two glass objects cannot drift apart. This one needs no shadow: it
          // sits inside the bottom scrim, which supplies its contrast.
          color: ArulTokens.overMediaGlassFill,
          shape: const CircleBorder(
            side: BorderSide(color: ArulTokens.overMediaGlassBorder),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            // The other commit verb — same weight as the primary.
            onTapDown: disabled ? null : (_) => ArulHaptics.firm(),
            onTap: disabled ? null : action.onTap,
            child: SizedBox(
              width: ReelActionBar.height,
              height: ReelActionBar.height,
              child: Center(
                child: _ActionGlyph(
                  action: action,
                  size: 21,
                  color: ArulTokens.ivory,
                  shadows: ArulTokens.railIconShadow,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ActionGlyph extends StatelessWidget {
  const _ActionGlyph({
    required this.action,
    required this.size,
    required this.color,
    this.shadows,
  });

  final ReelAction action;
  final double size;
  final Color color;
  final List<Shadow>? shadows;

  @override
  Widget build(BuildContext context) {
    final image = action.image;
    if (image == null) {
      return Icon(action.icon, size: size, color: color, shadows: shadows);
    }
    return Image(image: image, width: size, height: size, filterQuality: FilterQuality.medium);
  }
}

/// Hairline transfer bar across the top of the reel for an in-flight action.
/// Null [progress] renders indeterminate (a bar parked at 0% reads as stuck).
class ReelTransferBar extends StatelessWidget {
  const ReelTransferBar({super.key, required this.progress});

  final double? progress;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(gradient: ArulTokens.feedTopScrim),
      child: SizedBox(
        height: 3,
        child: LinearProgressIndicator(
          value: progress,
          minHeight: 3,
          backgroundColor: Colors.transparent,
          color: ArulTokens.gold,
        ),
      ),
    );
  }
}
