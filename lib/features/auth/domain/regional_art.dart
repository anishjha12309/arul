import 'package:flutter/widgets.dart';

/// One bundled launch poster: frame 0 of the region's most-applied live wallpaper, [wallpaperId].
///
/// A 9:16 master on a 9:19–9:20 phone crops only its SIDES, so no alignment can move a face up or
/// down. [zoom] about [pivot] does: it puts each face near 0.3 of the height — under the wordmark,
/// above the sign-in panel and Google's sheet — on every size the matrix covers (launch-surface.md).
final class RegionalPoster {
  const RegionalPoster(
    this.asset, {
    required this.wallpaperId,
    required this.zoom,
    required this.pivot,
    required this.faceY,
  });

  final String asset;

  /// The catalog row the poster was cut from. Its clip is found by id at run time, never by a
  /// bundled key: a CMS replace moves `full_key`, never the id.
  final String wallpaperId;

  final double zoom;
  final Alignment pivot;

  /// Where the face sits, as a fraction of the poster's height. Android crops a notification's big
  /// picture to its centre band, which on a 9:16 poster is the deity's waist -> the come-back post
  /// crops its own 2:1 band around this line.
  final double faceY;

  /// The live masters' frame (media-conventions.md). Poster and clip are both laid out in it, so
  /// the crossfade between them lands on the same pixels.
  static const frame = Size(1024, 1824);

  /// Face at 0.43 of the frame -> zoomed about the bottom edge to lift it clear of the panel.
  static const murugan = RegionalPoster(
    'assets/images/regional/murugan.webp',
    wallpaperId: '1039cdb4-f0ee-41a8-a005-3d9f6511927f',
    zoom: 1.2,
    pivot: Alignment.bottomCenter,
    faceY: 0.43,
  );

  /// Face at 0.25 -> zoomed about the top edge to drop it below the wordmark on 18:9 phones.
  static const ayyappan = RegionalPoster(
    'assets/images/regional/ayyappan.webp',
    wallpaperId: '4d4b4543-a2ca-47c5-b71c-b4867337358b',
    zoom: 1.15,
    pivot: Alignment.topCenter,
    faceY: 0.25,
  );

  /// The crossfade plays the whole clip -> a launch clip must stay one deity for its full loop.
  /// Face at 0.33 -> zoomed about the top edge to sit between the wordmark and the panel.
  static const sivan = RegionalPoster(
    'assets/images/regional/sivan.webp',
    wallpaperId: '1c340988-23d0-405b-9931-2778ad03c17e',
    zoom: 1.15,
    pivot: Alignment.topCenter,
    faceY: 0.33,
  );

  static const all = [murugan, ayyappan, sivan];
}

/// The owner-approved region table: Kerala takes Ayyappan, the Hindi belt Sivan, everyone else —
/// including no answer at all — the overall #1 Murugan. `/geo` sends the ISO code, or the state's
/// name when Cloudflare knows only that.
RegionalPoster regionalPosterFor(String? region) {
  final key = region?.trim().toUpperCase();
  return switch (key) {
    'KL' || 'KERALA' => RegionalPoster.ayyappan,
    'UP' ||
    'BR' ||
    'MP' ||
    'RJ' ||
    'HR' ||
    'JH' ||
    'CG' ||
    'UK' ||
    'HP' ||
    'UTTAR PRADESH' ||
    'BIHAR' ||
    'MADHYA PRADESH' ||
    'RAJASTHAN' ||
    'HARYANA' ||
    'JHARKHAND' ||
    'CHHATTISGARH' ||
    'UTTARAKHAND' ||
    'HIMACHAL PRADESH' => RegionalPoster.sivan,
    _ => RegionalPoster.murugan,
  };
}

/// What the launch surfaces (splash and wall) paint behind their type.
sealed class LaunchArt {
  const LaunchArt();
}

/// Today's lotus video over its poster: the control arm and every install outside the factorial.
final class LotusArt extends LaunchArt {
  const LotusArt();
}

/// The regional arm while the splash waits for `/geo`: dark ground and the wordmark, nothing else.
final class AwaitingRegionArt extends LaunchArt {
  const AwaitingRegionArt();
}

final class PosterArt extends LaunchArt {
  const PosterArt(this.poster);

  final RegionalPoster poster;

  @override
  bool operator ==(Object other) =>
      other is PosterArt && other.poster.asset == poster.asset;

  @override
  int get hashCode => poster.asset.hashCode;
}
