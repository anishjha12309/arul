import 'package:freezed_annotation/freezed_annotation.dart';

part 'wallpaper.freezed.dart';
part 'wallpaper.g.dart';

/// DB column `type`: 'static' or 'live'. `static` is a Dart keyword, so the
/// static-image case is named `image` and mapped via @JsonValue. A RENDERING
/// hint only — never a browse/filter axis (CLAUDE.md §5b).
enum WallpaperKind {
  @JsonValue('static')
  image,
  @JsonValue('live')
  live,
}

/// One feed item, parsed from the Worker-built catalog JSON
/// (`catalog/wallpapers/all_{page}.json`, snake_case fields — Arul's
/// build-catalog additionally emits `category`).
///
/// The field surface (id/title/category/categoryLabel/kind/key/width/height +
/// url/thumbUrl) is what the finished widgets consume — keep it stable.
@freezed
abstract class Wallpaper with _$Wallpaper {
  const Wallpaper._();

  @JsonSerializable(fieldRename: FieldRename.snake)
  const factory Wallpaper({
    required String id,
    required String title,

    /// Browse axis (amman·ayyappan·murugan·perumal·sivan·temples — free text;
    /// a 7th is a server-side insert). An unknown/missing category must never
    /// crash the feed — it falls into All (docs/edge-cases.md).
    @Default('other') String category,

    @JsonKey(name: 'type', unknownEnumValue: WallpaperKind.image)
    required WallpaperKind kind,

    /// R2 object key, e.g. `wallpapers/murugan/95b5276e.mp4`. Public by design
    /// (browse/preview are free); applying it is the premium gate.
    @JsonKey(name: 'full_key') required String key,
    int? width,
    int? height,

    /// How many times a premium user has APPLIED this wallpaper — the order of
    /// the All chip, and the only thing that orders it (`feedOrder()`).
    ///
    /// Counted server-side in `/media/signed-url`, never from analytics: the
    /// route sees 100% of real applies while PostHog is sampled and GA4 is a
    /// sink you'd have to poll. Shares do not count. See db/schema/06_popularity.sql
    /// for exactly what the number does and does not mean.
    ///
    /// Absent from an older cached catalog parses as 0, which sorts as "never
    /// applied" — correct, and it degrades that whole cached feed to plain
    /// newest-first rather than to something arbitrary.
    @Default(0) int applyCount,

    /// The admin's pin — tier 1 of [feedOrder], ahead of [applyCount].
    ///
    /// Written by hand in the CMS and sparse by convention (10, 20, 30 …) so a
    /// later drag renumbers one row instead of cascading the list. Ascending:
    /// the smallest rank leads the feed.
    ///
    /// **Null is the ordinary state, not a missing value** — ~all rows are
    /// unpinned, and they sort behind every pin on [applyCount] instead. That
    /// nullability is the feature's safety property: an import writes no rank, so
    /// a bulk drop can never displace the curated head. The first version of this
    /// column stored curation in `sort_order`, which every import reset.
    ///
    /// Nullable also means an older cached catalog — built before the field was
    /// emitted — parses as "nothing pinned" and simply falls back to the
    /// popularity order, rather than failing to parse.
    int? feedRank,
  }) = _Wallpaper;

  factory Wallpaper.fromJson(Map<String, dynamic> json) =>
      _$WallpaperFromJson(json);

  /// Chip/meta label, derived from the slug (capitalised). The catalog does not
  /// carry a display label; categories are single ASCII words by convention.
  String get categoryLabel => category.isEmpty
      ? category
      : category[0].toUpperCase() + category.substring(1);

  String url(String cdnBase) => '$cdnBase/$key';

  /// The 720px still used by the grid, and as the viewer's instant poster.
  ///
  /// Derived, not stored: thumbnails live under their OWN `thumbs/` prefix
  /// (deliberately not under `wallpapers/`, which the hourly orphan sweep owns)
  /// at `thumbs/<category>/<file-stem>.jpg`, where the stem is the basename of
  /// [key] without its extension. The catalog `id` is a DB UUID and has NO
  /// relation to the thumb name — always derive from the key, never from id.
  String thumbUrl(String cdnBase) {
    final name = key.split('/').last;
    final dot = name.lastIndexOf('.');
    final stem = dot == -1 ? name : name.substring(0, dot);
    return '$cdnBase/thumbs/$category/$stem.jpg';
  }

  /// The image every surface should ASK FOR first — tile, viewer poster, splash
  /// warm.
  ///
  /// **Only LIVE items have a `thumbs/` object.** The import writes `thumb_key`
  /// for video and nothing else (`tools/content-import/buildplan.mjs`), so a
  /// static asking for [thumbUrl] spends a guaranteed 404 round trip before its
  /// own fallback ladder fetches the full JPG it was always going to fetch. A
  /// static therefore goes STRAIGHT to [url]; it costs no extra bytes (the full
  /// image was the outcome either way) and saves the wasted request on every
  /// static card in the feed and in the splash warm window.
  ///
  /// Keep every caller on this one getter: the tile and the viewer's poster
  /// share a decode width, so they share a cache entry, and a caller that picked
  /// a different URL for the same item would decode it twice.
  ///
  /// Live is untouched — the poster-under-texture contract depends on it.
  /// (Backfilling real static thumbs is a content-pipeline job, not this.)
  String posterUrl(String cdnBase) =>
      kind == WallpaperKind.live ? thumbUrl(cdnBase) : url(cdnBase);
}

/// A browse chip. `all` is chrome (localised); the rest come from the catalog.
class WallpaperCategory {
  const WallpaperCategory(this.slug, this.label);

  final String slug;
  final String label;

  static const allSlug = '__all__';
}
