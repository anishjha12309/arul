import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../core/config/app_config.dart';
import '../../../app/theme/tokens.dart';
import '../../../data/models/wallpaper.dart';
import 'video_preload_controller.dart';
import 'wallpaper_tile.dart';

/// The media layer of one viewer page.
///
/// Layered, bottom to top:
///   1. the **poster** — the same 720px thumbnail the grid tile already decoded,
///      so opening a wallpaper is a repaint, not a refetch. It appears instantly.
///   2. for a static wallpaper, the full-resolution image, faded in over it.
///      for a live one, the native ExoPlayer texture, faded in on its first frame.
///
/// The poster stays mounted underneath for the whole life of the page. That is
/// the point: if the decode stalls, the network dies, or the clip errors, the
/// user keeps seeing a perfectly good image of the wallpaper they chose — never a
/// black frame, never a spinner, never a broken-image glyph. There is no
/// "waiting for video" state, because there is nothing worth waiting for.
///
/// **The cost of that, and it is the thing to know before debugging this:** a
/// live wallpaper whose texture has not revealed yet is PIXEL-IDENTICAL to a
/// static one. No shimmer, no spinner, no badge. So "none of the live wallpapers
/// are moving" is what a cold prefetch cache looks like (players stream ~5MB
/// each before the first frame) — it is not, on its own, evidence of a broken
/// pipeline. Check the pool, not the catalog.
class ViewerMedia extends StatelessWidget {
  const ViewerMedia({super.key, required this.wallpaper, this.slot});

  /// Where the visible window sits when `cover` has to crop.
  ///
  /// At the current card shape (1:1.86 vs the artwork's 9:16) the card is
  /// slightly TALLER than the source, so cover overflows horizontally and trims
  /// ~4.4% off the left and right. The `x: 0` here is what matters: a
  /// composition is centred, so an even trim off both margins is the right
  /// answer, and there is no vertical overflow for the `y` to act on.
  ///
  /// The `y: -0.45` is therefore dormant — and deliberately kept. It is load
  /// bearing the moment `FeedCardGeometry.cardAspect` drops below 1.78, where
  /// the crop flips to top/bottom: centred, a squarer card takes half its loss
  /// off the TOP, and on devotional art the top is the crown, the kireedam, the
  /// arch of the gopuram, while the bottom is skirt, plinth or background.
  /// Biasing the window up puts roughly three quarters of that loss below the
  /// subject instead. One constant, correct in both directions.
  ///
  /// Applies to every layer, and they must agree: the poster and the full image
  /// (or the video texture) are stacked, so a mismatch would visibly shift the
  /// frame the instant the real media faded in.
  static const cropAlignment = Alignment(0, -0.45);

  final Wallpaper wallpaper;

  /// The pooled player serving this page, when it is live AND inside the preload
  /// window. Null for a static wallpaper, and null for a live one that is outside
  /// the window — an off-window page holds no decoder. That IS the decoder budget.
  final LiveVideoSlot? slot;

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final fullWidth = (MediaQuery.sizeOf(context).width * dpr).round();

    return ColoredBox(
      // Behind the poster, for the frames before it decodes and in the letterbox
      // of any wallpaper that is not exactly the screen's aspect ratio.
      color: ArulColors.ink,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 1. Poster. Same URL ([Wallpaper.posterUrl]) AND the same decode width
          // as the grid tile, which makes this a cache HIT rather than a second
          // decode: memCacheWidth is part of the cache key, so decoding the same
          // poster at a different width would store a second copy of every
          // wallpaper the user opens.
          // The tile the user tapped is already decoded — this just repaints it.
          // It is briefly upscaled to full-bleed, which is fine: it is a poster
          // that lives for ~180ms until the real media fades in over it.
          CachedNetworkImage(
            imageUrl: wallpaper.posterUrl(AppConfig.cdnBaseUrl),
            fit: BoxFit.cover,
            alignment: cropAlignment,
            memCacheWidth: WallpaperTile.decodeWidthFor(context),
            fadeInDuration: Duration.zero,
            // No placeholder and no errorWidget: if the poster is missing, the
            // layer above covers this anyway. An error glyph here would flash
            // under a perfectly good full image.
            errorWidget: (_, _, _) => const SizedBox.shrink(),
          ),

          // 2. The real thing.
          if (wallpaper.kind == WallpaperKind.image)
            CachedNetworkImage(
              imageUrl: wallpaper.url(AppConfig.cdnBaseUrl),
              fit: BoxFit.cover,
              alignment: cropAlignment,
              // A 1080x1920 wallpaper decodes to ~8.3 MB of RGBA regardless of its
              // file size, so it is decoded at the screen's width, not its own.
              memCacheWidth: fullWidth,
              fadeInDuration: const Duration(milliseconds: 180),
              placeholder: (_, _) => const SizedBox.shrink(),
              errorWidget: (_, _, _) => const SizedBox.shrink(),
            )
          else if (slot != null)
            _LiveTexture(slot: slot!),
        ],
      ),
    );
  }
}

/// The live clip: a native ExoPlayer rendering into a Flutter [Texture].
class _LiveTexture extends StatelessWidget {
  const _LiveTexture({required this.slot});

  final LiveVideoSlot slot;

  @override
  Widget build(BuildContext context) {
    // Keyed by the POOLED PLAYER, not the page index. The pool reassigns a
    // physical player — and therefore its textureId and its notifiers — across
    // indices over a session. Keying by playerId forces a fresh element bound to
    // the new player whenever the player behind this page changes; keying by
    // index would leave a stale element pointed at another page's texture.
    return RepaintBoundary(
      key: ValueKey('viewer_video_${slot.playerId}'),
      child: ValueListenableBuilder<bool>(
        // Subscribe ONLY to this page's own first-frame flag, so a reveal
        // rebuilds this page and never its siblings — the thing that keeps a
        // swipe smooth while two or three players are in flight.
        valueListenable: slot.ready,
        builder: (context, ready, child) => AnimatedOpacity(
          opacity: ready ? 1 : 0,
          duration: const Duration(milliseconds: 180),
          child: child,
        ),
        child: ValueListenableBuilder<Size?>(
          valueListenable: slot.videoSize,
          builder: (context, size, child) {
            if (size == null || size.width <= 0 || size.height <= 0) {
              return const SizedBox.shrink();
            }
            // A raw Texture stretches to its box and does NOT cover-fit itself,
            // so wrap it: FittedBox(cover) around a SizedBox at the video's
            // intrinsic size scales and crops it to fill the page.
            return ClipRect(
              child: FittedBox(
                fit: BoxFit.cover,
                // Same bias as the static path — see [ViewerMedia.cropAlignment].
                // A live clip whose crop disagreed with its own poster would jump
                // the moment the first frame landed.
                alignment: ViewerMedia.cropAlignment,
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
