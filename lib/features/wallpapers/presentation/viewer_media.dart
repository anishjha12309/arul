import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../core/config/app_config.dart';
import '../../../data/models/wallpaper.dart';
import 'video_preload_controller.dart';

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
class ViewerMedia extends StatelessWidget {
  const ViewerMedia({super.key, required this.wallpaper, this.slot});

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
      color: const Color(0xFF131011),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 1. Poster. Same URL, same cache key, same decoded bytes as the grid.
          CachedNetworkImage(
            imageUrl: wallpaper.thumbUrl(AppConfig.cdnBaseUrl),
            fit: BoxFit.cover,
            fadeInDuration: Duration.zero,
            // No placeholder and no errorWidget: if the poster is missing, the
            // layer above it covers this anyway. An error glyph here would flash
            // under a perfectly good full image.
            errorWidget: (_, _, _) => const SizedBox.shrink(),
          ),

          // 2. The real thing.
          if (wallpaper.kind == WallpaperKind.image)
            CachedNetworkImage(
              imageUrl: wallpaper.url(AppConfig.cdnBaseUrl),
              fit: BoxFit.cover,
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
