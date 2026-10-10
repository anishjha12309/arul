import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../app/theme/motion.dart';
import '../../../app/theme/tokens.dart';
import '../../../app/widgets/reel/reel_card.dart';
import '../../../app/widgets/reel/video_preload_controller.dart';
import '../../../core/config/app_config.dart';
import '../../../data/models/wallpaper.dart';
import 'feed_states.dart';
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
            // Until the poster lands the card is ink on an ink frame -> invisible, with the action
            // row floating in the void. The loading card's sweep marks the card as arriving instead;
            // it leaves the moment the poster paints, so the reveal rule below is untouched.
            placeholder: (_, _) => const ReelPosterPlaceholder(),
            // The layer above covers a missing poster -> an error glyph would flash under a good
            // full image -> no error widget here.
            errorWidget: (_, _, _) => const SizedBox.shrink(),
          ),

          if (wallpaper.kind == WallpaperKind.image)
            CachedNetworkImage(
              imageUrl: wallpaper.url(AppConfig.cdnBaseUrl),
              fit: BoxFit.cover,
              alignment: cropAlignment,
              // RGBA decode cost ignores file size (~8.3 MB at 1080x1920) -> decode at the screen's
              // width, never the image's own.
              memCacheWidth: fullWidth,
              fadeInDuration: Motion.imageFade,
              placeholder: (_, _) => const SizedBox.shrink(),
              errorWidget: (_, _, _) => const SizedBox.shrink(),
            )
          else if (slot != null)
            ReelLiveTexture(slot: slot!, alignment: cropAlignment),
        ],
      ),
    );
  }
}
