import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/tokens.dart';
import '../../../app/widgets/skeleton.dart';
import '../../../core/config/app_config.dart';
import '../../../data/models/wallpaper.dart';
import '../providers/catalog_providers.dart';

/// One grid tile: pure image, nothing else.
///
/// No caption, no title and no live/static marker. At 190dp the image IS the
/// information, and no text means no truncation to fight across six languages —
/// Tamil, Telugu, Kannada and Malayalam labels are all materially longer than
/// their English equivalents. The play-arrow glyph that used to mark live items
/// went the same way as the reel's LIVE pill (2026-08-11): `type` is a rendering
/// hint, never something the user browses by (CLAUDE.md §5b).
///
/// A tile NEVER creates a video surface. That is the entire reason the grid is
/// affordable: the hardware decoder stays idle until the user deliberately opens
/// the viewer.
class WallpaperTile extends ConsumerWidget {
  const WallpaperTile({
    super.key,
    required this.wallpaper,
    required this.onTap,
  });

  final Wallpaper wallpaper;
  final VoidCallback onTap;

  static const radius = Radii.tileShape;

  /// Decode at the tile's real size, not the source's.
  ///
  /// cacheWidth is in RAW pixels, so it must be scaled by devicePixelRatio or the
  /// tile ships blurry. The VIEWER's poster deliberately calls this too: the
  /// decode width is part of the image cache key, so decoding the same thumbnail
  /// at a different width there would store a second copy of every wallpaper the
  /// user opens, instead of reusing the one already on screen.
  static int decodeWidthFor(BuildContext context) =>
      (200 * MediaQuery.devicePixelRatioOf(context)).round();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final decodeWidth = decodeWidthFor(context);

    return Semantics(
      button: true,
      label: wallpaper.title,
      child: GestureDetector(
        onTap: onTap,
        child: ClipRRect(
          borderRadius: radius,
          child: ColoredBox(
            color: scheme.surfaceContainerHighest,
            // No Hero: the viewer has no matching destination, so the flight
            // never ran. The continuity comes from the poster instead — the
            // viewer opens on the exact image this tile already decoded.
            child: _TileImage(wallpaper: wallpaper, decodeWidth: decodeWidth),
          ),
        ),
      ),
    );
  }
}

/// The tile's image, with its fallback ladder.
///
/// 1. [Wallpaper.posterUrl] — the pre-generated 720px thumbnail (`thumbs/…`) for
///    a LIVE clip, and the full image itself for a static, which has no thumb
///    object to ask for. Either way these are the same bytes the viewer reuses
///    as its instant poster.
/// 2. If that 404s (a live clip published before the thumbnail job ran):
///    - live  → the clip's first frame, pulled natively over a ranged read.
///    - static → the full image, decoded down to tile size (same URL as step 1;
///      reached only when that genuinely failed, so it is a plain retry).
/// So a missing thumbnail degrades a tile's *cost*, never its correctness. It is
/// never a hole.
class _TileImage extends ConsumerWidget {
  const _TileImage({required this.wallpaper, required this.decodeWidth});

  final Wallpaper wallpaper;
  final int decodeWidth;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return CachedNetworkImage(
      imageUrl: wallpaper.posterUrl(AppConfig.cdnBaseUrl),
      fit: BoxFit.cover,
      memCacheWidth: decodeWidth,
      fadeInDuration: const Duration(milliseconds: 180),
      placeholder: (_, _) => const Skeleton(borderRadius: BorderRadius.zero),
      errorWidget: (_, _, _) =>
          _TileFallback(wallpaper: wallpaper, decodeWidth: decodeWidth),
    );
  }
}

class _TileFallback extends ConsumerWidget {
  const _TileFallback({required this.wallpaper, required this.decodeWidth});

  final Wallpaper wallpaper;
  final int decodeWidth;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;

    if (wallpaper.kind == WallpaperKind.image) {
      return CachedNetworkImage(
        imageUrl: wallpaper.url(AppConfig.cdnBaseUrl),
        fit: BoxFit.cover,
        memCacheWidth: decodeWidth,
        placeholder: (_, _) => const Skeleton(borderRadius: BorderRadius.zero),
        errorWidget: (_, _, _) => _TileBroken(color: scheme.onSurfaceVariant),
      );
    }

    final thumbs = ref.watch(videoThumbnailServiceProvider);
    return FutureBuilder<File?>(
      future: thumbs.thumbnail(wallpaper.url(AppConfig.cdnBaseUrl)),
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Skeleton(borderRadius: BorderRadius.zero);
        }
        final file = snap.data;
        if (file == null) return _TileBroken(color: scheme.onSurfaceVariant);
        return Image.file(
          file,
          fit: BoxFit.cover,
          cacheWidth: decodeWidth,
          gaplessPlayback: true,
        );
      },
    );
  }
}

/// A tile whose media genuinely cannot be shown (dead object, hard offline with a
/// cold cache). Muted, not alarming: one broken wallpaper is not an app error, and
/// the grid around it still works.
class _TileBroken extends StatelessWidget {
  const _TileBroken({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Icon(
        Icons.image_not_supported_outlined,
        size: 24,
        color: color.withValues(alpha: 0.6),
      ),
    );
  }
}
