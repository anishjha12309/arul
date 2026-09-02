import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../core/config/app_config.dart';
import '../../../app/theme/tokens.dart';
import '../../../data/models/wallpaper.dart';
import 'video_preload_controller.dart';
import 'wallpaper_tile.dart';

/// The media layer of one page: poster below, full image or ExoPlayer texture faded in above.
///
/// Poster stays mounted for the page's whole life -> a stalled decode, dead network or clip error
/// still shows the chosen wallpaper -> never a black frame, a spinner or a broken-image glyph.
/// An unrevealed live texture is pixel-identical to a static card -> "nothing is moving" is a cold
/// prefetch cache (~5MB per clip before frame one) -> check the pool, not the catalog.
class ViewerMedia extends StatelessWidget {
  const ViewerMedia({super.key, required this.wallpaper, this.slot});

  /// Where the visible window sits when `cover` has to crop.
  ///
  /// The reel height-clamps the card BELOW the 1.78 source ratio -> cover trims top/bottom, not the
  /// sides -> `y: -0.45` is LIVE on real phones (feed_card_geometry_test.dart), never dormant.
  /// Centred, a squarer card loses half its height off the TOP — crown, kireedam, gopuram arch ->
  /// bias up so ~3/4 of the loss falls on skirt and plinth instead.
  /// `x: 0` is the other direction: a tall enough screen grants 1.86 and the trim flips to the
  /// margins, where an even cut suits a centred composition. One constant, correct both ways.
  /// Poster, full image and texture are stacked -> a mismatch shifts the frame on fade-in -> every
  /// layer uses this one alignment.
  static const cropAlignment = Alignment(0, -0.45);

  final Wallpaper wallpaper;

  /// The pooled player for this page, when live AND inside the preload window.
  ///
  /// Null for a static wallpaper and for an off-window live one -> that page holds no decoder ->
  /// this nullability IS the decoder budget.
  final LiveVideoSlot? slot;

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final fullWidth = (MediaQuery.sizeOf(context).width * dpr).round();

    return ColoredBox(
      // Shows before the poster decodes and in any letterbox -> ink, never white.
      color: ArulColors.ink,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // memCacheWidth is part of the cache key -> a different width stores a second copy of
          // every opened wallpaper -> match the grid tile's URL and decode width exactly, for a hit.
          // Upscaling to full-bleed is fine: this poster lives ~180ms until the real media lands.
          CachedNetworkImage(
            imageUrl: wallpaper.posterUrl(AppConfig.cdnBaseUrl),
            fit: BoxFit.cover,
            alignment: cropAlignment,
            memCacheWidth: WallpaperTile.decodeWidthFor(context),
            fadeInDuration: Duration.zero,
            // The layer above covers a missing poster -> an error glyph would flash under a good
            // full image -> no placeholder and no error widget here.
            errorWidget: (_, _, _) => const SizedBox.shrink(),
          ),

          // 2. The real thing.
          if (wallpaper.kind == WallpaperKind.image)
            CachedNetworkImage(
              imageUrl: wallpaper.url(AppConfig.cdnBaseUrl),
              fit: BoxFit.cover,
              alignment: cropAlignment,
              // RGBA decode cost ignores file size (~8.3 MB at 1080x1920) -> decode at the screen's
              // width, never the image's own.
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
          duration: const Duration(milliseconds: 180),
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
                fit: BoxFit.cover,
                // A clip cropped differently from its own poster jumps on first frame -> same bias
                // as the static path, [ViewerMedia.cropAlignment].
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
