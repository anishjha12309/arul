import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/tokens.dart';
import '../../../app/widgets/skeleton.dart';
import '../../../core/config/app_config.dart';
import '../../../data/models/wallpaper.dart';
import '../providers/catalog_providers.dart';

/// One grid tile — pure image, nothing else.
///
/// At 190dp the image IS the information -> no caption, no title, no live/static marker.
/// No text also means no truncation to fight across six languages, four of them far longer.
/// `type` is a rendering hint, never something the user browses by (CLAUDE.md §5b).
/// A tile NEVER creates a video surface -> the decoder stays idle until the viewer opens.
/// That is the entire reason the grid is affordable.
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
  /// cacheWidth is in RAW pixels -> scale by devicePixelRatio, or the tile ships blurry.
  /// The VIEWER's poster calls this too: the decode width is part of the image CACHE KEY.
  /// A different width there would store a second copy of every wallpaper the user opens.
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
            // No Hero — the viewer has no matching destination, so the flight never ran.
            // Continuity comes from the poster: the viewer opens on the image this tile decoded.
            child: _TileImage(wallpaper: wallpaper, decodeWidth: decodeWidth),
          ),
        ),
      ),
    );
  }
}

/// The tile's image, with its fallback ladder.
///
/// 1. [Wallpaper.posterUrl] — the 720px `thumbs/` object for a LIVE clip, the full image for a static.
///    A static has no thumb object to ask for. Either way, the same bytes the viewer reuses.
/// 2. If that 404s, i.e. a live clip published before the thumbnail job ran:
///    - live  → the clip's first frame, pulled natively over a ranged read;
///    - static → the full image at tile size; the same URL, so a plain retry.
///
/// A missing thumbnail degrades a tile's COST, never its correctness — it is never a hole.
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

/// A tile whose media genuinely cannot be shown — a dead object, or offline with a cold cache.
/// Muted, not alarming: one broken wallpaper is not an app error, and the grid still works.
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
